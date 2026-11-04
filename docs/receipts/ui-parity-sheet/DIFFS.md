# iOS ↔ Android 逐张差异清单（L64，2026-11-02）

复核这份清单要三样东西，都在仓库里：

1. `docs/receipts/ui-parity-sheet/<state>__ios-left.png` —— 并排图，左 iOS、右 Android，
   同一个缩放系数、顶对齐，左边有 frame px 标尺。
2. 本文坐标：**pt = px / 3**（402×874 pt @3× 框），全部在 1206×2622 的原图上量。
   并排图是 0.5× 缩放，`pt = (sheet_y − 114) × 2 / 3`。
3. 测法：逐行取「非背景墨迹」的 y 带与 x 范围，再取该带最暗 1/12 像素的中位色作为字色；
   色块取出现次数最多的饱和色。**没有做像素 diff**（两平台字体栅格不同，diff 数字无意义）。

读字号的规矩：字体栅格不同，**同字号的中文墨高不同**——17 pt 的 CJK 在 iOS 上墨高 15.3 pt，
在 Android 上 16.3–17.0 pt。所以判断字号只用**同一个字符串**两边的墨高比，或回读
`examples/.../**.swift` 里的 `.font(...)`。下文写「墨高」的地方都是这个意思。

## 一条贯穿全集的已知偏移（不是缺陷）

iOS 截图带模拟器状态栏（墨迹 **y 13.7–50.7 pt**，安全区 62 pt），Android 隐藏系统栏。
因此 iOS 的内容整体比 Android 低 **约 61–62 pt**。下文「扣除 chrome 后」= `iOS y − 61.3`
（settings 家族实测 61.3；其余页因顶栏结构不同，落在 57.7–64.7 之间，逐条写明）。

---

# 一、settings 家族（7 张）

## page-settings-default

iOS 是 `ios-settings.png`：白色 44 pt 导航条（居中 17 pt 标题 `通用设置` + 右上白色胶囊 `完成`）
+ 5 段选择器（#EEEEEF 胶囊轨道）+ 4 张内嵌分组卡。Android 是 `SettingsPage` 通用 tab。

| 控件 | iOS | Android（修前） | Android（修后） | 差 |
|---|---|---|---|---|
| 导航条底色 | #FFFFFF，y 0–166.7 | #F2F3F5（页面灰），y 0–140.3 | 同左 | 无白条 |
| 标题 `通用设置` 墨迹 | y 76.7–92.0，h 15.7 | y 14.7–30.7，h 16.3 | 同左 | 扣 chrome 后 Δ1.7 pt |
| `完成` | 黑字 17 pt，ink x 337.0–368.7；**白色胶囊** y 60.0–104.7、x 302.7–389.7 | 蓝字 #3964FE，ink x 346.7–379.0，**无底** | 同左 | 一个胶囊控件缺失；右缘 +10.3 pt |
| 选择器轨道 | #EEEEEF 胶囊，y 126.0–157.7 | 无轨道（页面灰即底），白药丸选中 | 同左 | 轨道填充缺失 |
| 卡片 1 顶 | y 202.0 | y 140.7 | y 140.7 | 扣 chrome 后 Δ0.0 |
| 卡片 2 顶 | y 341.7 | y 284.0 | **y 280.3** | 修前 Δ3.7 → 修后 Δ0.1 |
| 卡片 3 顶 | y 586.0 | y 532.0 | **y 524.7** | 修前 Δ7.4 → 修后 Δ0.0 |
| 卡片 4 顶 | y 830.3 | y 780.0 | **y 769.0** | 修前 Δ11.3 → 修后 Δ0.0 |
| 卡片间距 | 35.0（4 条带：920→1024 等） | 38.7 | **35.0** | 修前 +3.7 pt/段，累积到第 4 张卡 11.3 pt |
| 卡片左右 | x 16.0–385.3 | x 16.0–385.3 | 同左 | 0 |
| 开关 bbox | x 309.0–371.7 × y 703.0–730.7（h 27.7） | x 283.7–346.3 × y 648.0–677.3（h 29.3） | **x 309.0–371.7** × y 640.7–670.0（h 29.3） | 修前水平偏左 25.3 pt；修后 0（高度仍 +1.6 pt） |
| 开关颜色 | **#34C759**（systemGreen，7078 px） | **#3964FE**（accent token，11296 px） | 同左 | 色相完全不同；无 token，未改（见 §8） |
| 额外卡片 | 无 | 第 6 张 `性能与用量`（y 832.3 起） | 同左 | Android 多一张 |

## page-settings-model

iOS 是**独立 sheet**（`ModelProviderSettingsPage`）：没有分段选择器，34 pt 大标题 `模型服务`。

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 容器 | 无分段选择器；大标题 y 125.7 起 | 设置 shell 的 5 段选择器 y 44.7–73.3；大标题 y 68.0–100.3 | Android 多一层 shell（注册表说「两边都是 模型 tab」，图上 iOS 没有 picker） |
| `服务` 分组头 | y 180.7，x 32.7（无折叠箭头） | y 124.0，x 33.7，带 `⌄` + 右侧 `1 项` | Android 多折叠箭头与计数 |
| 选中标记 | 蓝色实心圆勾 #0088FF，x 320.0–333.3 | 无圆勾；右侧文字 `默认 未知` | 控件不同 |
| 行内容 | `默认模型服务 [默认]` + URL + 模型 + `读不到密钥`（橙） | `模型 deepseek-flash` / `服务 api.deepseek.com` / `读取不到这项状态，未做任何假设` | 每行内容模型不同 |
| 动作 | 图标行 `添加模型服务` / `编辑默认服务`（⊕、滑杆图标）+ 2 条分隔线 | 纯文字链接 `编辑` `删除` / `添加模型服务` / `编辑默认服务`，无分隔线 | 图标与分隔线缺失 |
| `生效方式` | 左对齐 x 32.7，y 780.0 | **缩进到 x ~86 pt**（居中显示），y 500.7 | Android 错位 ~53 pt |
| 大标题字 | 墨高 30.0（34 pt/700） | 墨高 32.7（34 sp/700） | 同字号（raster 差） |

## page-settings-search

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 大标题 `网页搜索` | y 125.7–155.3，墨高 30.0 | y 68.0–100.3，墨高 32.7 | 扣 chrome 后 Δ0.0；同字号 |
| 关闭控件 | 无 | 蓝色 `✕` x 23.0–35.3，y 17.0–29.7 | Android 多一个关闭键（iOS 是 push 页） |
| 分组头 `用哪一份搜索` | #8A8A8E，墨高 15.3 | #66666B，墨高 16.3 | 色差：#8A8A8E vs token #66666B |
| 选项 1 标题 | #111114，y 234.0 | **蓝色 #3964FE**（选中态染色） | 选中项颜色不同 |
| 勾选标记 | 蓝勾 x 330 起 | 蓝勾 x 371 起 | Δ约 40 pt |
| `现在这个模型服务自带搜索…` | #8A8A8E，墨高 13.0（13 pt） | #66666B，墨高 13.3 | 只有色差 |
| `什么时候生效` | y 422.7，x 32.7 | y 331.7，x 33.7 | 位置扣 chrome 后 Δ2.3 |
| `还要知道` 三段正文 | 墨高 16.7，行距 22.3（17 pt） | 墨高 13.3，行距 16.3（13 sp） | **字号 14 vs 17**；修后墨高 17.7，行距 20.3 |
| `启动本地引擎` | #0088FF，墨高 15.7（17 pt） | #3964FE，墨高 12.3（≈13 sp），x 6.3 起 | 字号 13 vs 17；左边距 6.3 vs 32.7 |

## page-settings-network

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 页面标题 | `网络访问`（17 pt，居中，y 65.0） | `出网白名单`（17 sp 粗体，居中，y 19.0） | 文案不同；注册表/契约写的是 `网络访问` |
| 顶栏左侧 | 无控件 | 蓝色 `✕` x 23.0–35.3 | Android 多一个 |
| `允许连任何网站` 行 | y 153.0，开关 x 309–371（关，灰 #C5C5C7） | y 65.0，开关 x 306–350（关） | 行位置扣 chrome 后 Δ0.7；开关位置差 ~21 pt |
| 地址列表行高 | 52.33 pt（wttr.in y 264.0 → api.open-meteo y 318.7） | 35.0 pt（wttr.in y 148.0 → api 183.0） | **17.3 pt/行** |
| 列表行内容 | 单行主机名（17 pt） | 两行：主机名 + `精确主机 任意 http(s) scheme · 任意端口` | Android 多一行说明 |
| 行尾控件 | 无 | 每行右侧 `⋯` | Android 多一个 |
| 文字色 | #000000 | #111114 | 见 §8：iOS 用系统 .primary=纯黑 |
| 分隔线 | 起始 x 43 pt | 起始 x 16 pt | 缩进差 27 pt |
| 悬空 Material 色 | — | #E6E0E9 出现 8584 px、#9A9AA2 61205 px | 非 token 色（见 §8） |

## page-settings-plugins

| 控件 | iOS | Android（L64 修前） | Android（L76 修后） | 差 |
|---|---|---|---|---|
| 页面标题 | `插件`（34 pt 大标题，y 285 起） | `本会话设置`（34 sp 大标题，y 68.0 起） | `插件` | 无（L67 已改） |
| 顶栏 | 白色胶囊 `完成` | 蓝字 `完成` | 蓝字 `完成`（`刷新` 已从工具栏移回页内胶囊） | 同 settings-default |
| 三个玻璃胶囊 | `插件说明` / `刷新` / `添加插件`，y 415–505，x 130–580 | 无胶囊；只有纯文字 `插件说明` `添加插件`（**无 `刷新`**） | **三个胶囊齐了**：x 16.7–131.0 / 142.7–223.0 / 234.7–349.0，高 **34.5 pt**（iOS 34.33），底 `#E9E9EB`（新 token `colors.glassPillFill`），蓝字 + ⓘ/↻/＋ 矢量图标 | 胶囊有了；标签单行（iOS 被挤成两行） |
| 告警条 | 橙色 ⚠ `请先启动 DSH 主机，再读取插件和设置。` y 604–670 | 无 | **橙色 ⚠ + 橙字**两行（新 token `colors.systemOrange`），y 353.3–392.3；文案多 `部分设置读取失败：` 前缀 | 控件有了；文案前缀是 Android 的（三次读各自的失败） |
| 行图标 | 每行前置 ⓘ / 🌐 图标 | 无图标 | **🌐 有了**（`GlobeGlyph`，蓝，在 `网页搜索与抓取` 行）；ⓘ 仍无 | ⓘ 属于「分组缺失时的占位行」，Android 没有这个概念（见 L76-6） |
| 子行 | `子 Agent` / `子 Agent 模型` / `自动执行轮次` / `终端` | `读写状态 可修改` ×2、`允许派生子 Agent`、`默认 Shell /system/bin/sh` | 同左 | 行集合不同（宿主给的 group 与 iOS 硬编码的四个 namespace 不同名） |
| 分隔线 | 6 条 | 无（L64 当时；L74 换行组件后已有） | **6 条**（y 293/345/532/585/728/780 pt） | 已对齐 |

## page-settings-about

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 背景 | #F2F2F7 主导（2.77 M px） | #FFFFFF 主导（1.75 M px）+ #F2F3F5 | 卡片面积不同 |
| 卡片数 | **1 张**（y 170–270） | **3 张**（版本 / 系统 / 更多） | Android 多 2 张 |
| 卡片折叠头 | 无（直接一行 `版本 0.1.0`） | 每张卡有 `⌄ 版本 2 项` | Android 多折叠头 |
| 行 | `版本 0.1.0` + 脚注 `会话记录和文件都保存在这台手机上。` | `版本号 0.1.0` / `构建号 1`；`Android 15` / `API 级别 35` / `ABI arm64-v8a` / `设备 sdk_gphone64_arm64` / `WebView 131…`；`开源许可 不可用 ›` | 行集合不同（Android 是平台附录） |
| 顶栏 | `关于` 17 pt 居中 | `关于` 17 sp 粗体居中 + 蓝 `✕` | 多了关闭键 |

## page-settings-runtime

| 控件 | iOS | Android（L64 修前） | Android（L76 修后） | 差 |
|---|---|---|---|---|
| 大标题 | `运行状态`（34 pt，y 300 起） | `运行时详情`（34 sp，y 68.0 起） | `运行状态` | 无（L67 已改） |
| 内容量 | 5 块：`状态 已停止`、`最近出错`、`最近没有出错`、`启动本地引擎`、脚注 | 8 个折叠段：本次运行 3 项 / 最近出错 1 项 / 引擎 2 项 / 已运行 / WebView 3 项 / 内存 3 项 … | **引擎 1 行 / 本次运行 / 最近出错 / 动作+脚注 / WebView / 内存 / 电源与散热 / 前台服务**（7 段：iOS 的 3 块顺序 + 4 个 androidOnly） | 仍多 4 段（契约 `_android-only-items.json` 注册，见 L76-1） |
| `读取不到这项状态，未做任何假设` | 0 次 | **6 次** | **0 次**：收敛成页首 2 行（`这台宿主没有报告这些状态：…` + 规则句） | 已收敛（见 L76-3） |
| 状态行 | 一行 `状态 已停止`（运行中时 `运行中 · 已运行2 分钟`） | `引擎` 段里两行：`状态` + `已运行` | **一行** `状态 = 已停止` / `运行中 · 已运行2 分钟` | 已合并（见 L76-2） |
| 分组头 | 13 pt 裸标题，无计数、无折叠 | `⌄ 本次运行  3 项` | `⌄ 引擎`（计数已删，折叠保留） | 折叠是 Android 自己的 affordance |
| 动作脚注 | `停止后,正在跑的任务会停下来,不会再接着做。` 两个分支都画 | 只在「停止」分支 | **两个分支都画** | 已对齐 |
| 关闭/返回 | 无 | 蓝色 `✕` x 23.0–35.3 | 同左 | 多一个控件（设置族共用） |
| 分隔线 | 2 条 | 每行一条 | 每行一条 | 数量不同（列表行自带） |

---

# 二、sessions 家族（7 张）

## 公共差异（除 schedules 外的 6 张）

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 抽屉宽度 | 满宽 402 pt（搜索框 x 30–370，CTA x 16–385.7） | 320 pt 抽屉（内容 x 16–303.7） | **CTA 宽度 369.7 vs 287.7 pt（差 82）** |
| 搜索框 | y 100.7–144.0，x 30.0–370.0，白底 + 放大镜 | y 49.3–88.7，x 26.3–312.7 | 高度 43.3 vs 39.3；位置扣 chrome 后 Δ7.3 |
| 会话行前导图标 | `bubble.left` 墨迹 16.0×15.3，x 24.3–40.0 | 修前：字符 `▢`，墨迹 9.7×10.3，x 25.3 | **形状/大小/基线都不同**；修后：矢量气泡 17.0×15.7，x 24.0–40.7 |
| 行高 | 56.0 pt（20 行实测 345.0→401.0） | 56.7 pt（263.0→319.7） | +0.7 pt/行，20 行累积 +14 pt |
| 行标题字号 | 17 pt（墨高 15.3） | 17 sp（墨高 16.3–24.0，含图标带） | 同字号 |
| 行时间字号 | 13 pt（墨高 12.7） | 13 sp（墨高 11.0–11.3） | 同量级 |
| 次级文字色 | #8A8A8E / #66666B | #66666B / #9A9AA2 | 见 §8 |
| 行尾 `⋯` | `•••`（三点，较大） | `⋯`（三点，较小） | 字形不同 |
| 新建会话行色 | #C3C3C6（禁用） | #9A9AA2 | 色差 |
| 已归档 | `› 已归档  0`，y 1117（sheet） | `› 已归档  0`，y 763（sheet） | 扣 chrome 后位置接近 |

## page-sessions-default

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 搜索占位墨迹 | y 130.7–146.7，墨高 16.3 | y 66.7–82.7，墨高 16.3 | 扣 chrome 后 Δ2.7 |
| `+ 新建会话` | y 194.3–210.0，x 18.3–111.0 | y 143.0–158.3，x 16.7–102.7 | 扣 chrome 后 Δ10.7 |
| `新建会话` 下分隔线 | 有（y 214.6） | **无** | 缺失 |
| `先启动本地引擎,才能新建会话。` | y 250.7，墨高 12.7 | y 188.7，墨高 13.3 | 扣 chrome 后 Δ0.7 |
| `还没有工作文件夹` | 居中（中心 200.9），墨高 15.7 | 居中于 320 抽屉（中心 159.7），墨高 16.3 | **居中基准差 41.2 pt** |
| CTA `新建工作文件夹` | y 348.7–398.3，x 16.0–385.7，h 50.0，#2F5BFF | y 303.7–353.3，x 16.0–303.7，h 50.0，#2F5BFF | 高一致；宽差 82 pt |
| 返回键 | 无 | `‹` 墨迹 x 22.7–25.0，y 20.3–25.0 | Android 多一个 |

## page-sessions-nothing

**这一张不可能对。** `android/.../ios-parity/page-sessions-default.png` 与
`page-sessions-nothing.png` 是**同一个文件**（md5 `64dcaccb…`，byte-identical），而两张 iOS 图不同
（diff 74,939 px，行 223.7–398.3 pt）。所以 `page-sessions-nothing` 的「captured」是假的：
Android 用一张图顶了两个注册状态。差异同 page-sessions-default（iOS 侧另有
`this capture equals page-sessions-nothing` 的注册表注记自认）。

## page-sessions-empty

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| `项目资料` 分组头 | y 288.7（sheet 547） | y 224.0（sheet 450） | 扣 chrome 后 Δ2.0 |
| 分组头 `•••` / `⋯` | `•••` x 222.7 | `⋯` x 227.3 | 字形与位置 |
| `还没有会话` | y 588.7，墨高 15.3 | y 275.3（sheet 880 → 510）… 见行 | 行距压缩 |
| `点上面的「新建会话」开始。` | 13 pt | 13 sp | 同量级 |
| 每行之间的留白 | 分组块之间 ~35 pt | ~12 pt | Android 更紧 |
| `+ 添加工作文件夹` | 17 pt，#007AFF 系 | 17 sp，蓝 | 字号同 |
| `› 已归档  0` | y 848 | y 763 | — |

## page-sessions-many

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 行前导图标 | 气泡 16.0×15.3 | `▢` 9.7×10.3（修前）→ 气泡 17.0×15.7（修后） | 修前形状不符；修后 Δ1.0 pt 宽 |
| 行标题 | 17 pt，x 51.0 | 17 sp，x 51.7 | Δ0.7 |
| 行距 | 56.0 | 56.7 | +0.7/行 |
| 分组 `项目资料 · 20 个会话` | y 299.3，`•••` x 222.7 | y 223.0，`⋯` x 228.0 | 扣 chrome 后 Δ13.0 |
| 行右侧勾选 | 当前会话有 `✓`（20 pt） | 无 | 未验证（本图无选中项） |

## page-sessions-ungrouped

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 行距 | 56.0（预览 1 y 345.0 → 预览 2 y 401.0） | 56.7（y 263.0 → 319.7） | +0.7 |
| 首行顶 | y 345.0 | y 263.0（修前 263.0，图标改后同） | 扣 chrome 后 Δ20.7 |
| `添加工作文件夹` | y 489.0，x 32.7 | y 433.0，x 16.7 | 左边距差 16 pt |
| 行前导图标 | 气泡 | `▢` → 气泡 | 同 many |

## page-sessions-error

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 失败行 | `读不到会话` + `重试`（红/蓝） | 有同类行，颜色 `#C0392B` | 色值不同（token danger=#C0392B，iOS 用系统红） |
| 行距 | 56.0 | 56.7 | +0.7 |
| 重试行 `重试` | 17 pt | 17 sp | 同 |

## page-sessions-schedules

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 背景 | #FFFFFF | #F2F3F5 | 底色不同 |
| 左上控件 | **圆形玻璃按钮 ↻**（y 204–270，白圆 + 阴影） | 蓝字 `✕` + 蓝字 `刷新`（x 22.7 / 50.0） | 控件不同 |
| 右上 `新建` | **白色胶囊**（y 204–270） | 蓝字（y 14.7–30.7） | 胶囊缺失 |
| 大标题 `定时任务` | y 300–366，墨高 30.3 | y 68.0–100.3，墨高 32.7 | 扣 chrome 后 Δ0.0 |
| 空态标题 | y 410.0，墨高 15.7 | y 127.0，墨高 16.3 | 扣 chrome 后 Δ7.0 |
| CTA `新建任务` | y 500.0–560.0，x 20.0–330.0（w 310） | y 203.3–251.0，x 16.0–303.7（w 287.7） | 宽差 22.3 |
| `需要处理` 分组头 | #8A8A8E，墨高 15.3 | #66666B，墨高 12.0（13 sp） | **字号 13 vs 17** |
| 错误正文 | 17 pt 红字，两行 y 720.0/738.0 | 13 sp 红字，两行 y 320.7/333.3 | 字号 13 vs 17 |
| 顶栏底色 | 白 | 灰 | 同 settings |

---

# 三、chat 家族（8 张）

## 公共差异

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 顶栏 | 44 pt：侧栏图标 x 20.3、居中标题 17 pt、右侧手机图标 + `•••` | 44 dp：`☰` x 22.7、居中标题 17 sp、`● 未启动/运行中` + `⋯` | 右侧控件集合不同；标题粗体不同 |
| 正文行文字 | **17 pt**（墨高 16.0–16.7） | **14 sp**（墨高 13.3–13.7） | 3 pt；token `body=14` 与基线矛盾（§8） |
| 正文左边距 | x 32.7 | x 16.7 | 16 pt |
| 气泡（用户） | 灰底，右缘 x 352.7 | 灰底，右缘 x 368.7 | 16 pt |
| composer | y 756.7 起（占位 17 pt） | y 766.3 起（占位 14 sp） | 字号与位置 |
| 统计行 | 17 pt，带 `○` 环形图标 | 14 sp | 字号与图标 |
| 语法着色 | 代码块有颜色（字符串 #22C55E，关键字蓝） | 全 #111114 | 无高亮 |

## page-chat-default

iOS 是另一段对话（注册表自认），所以按结构列：

| 控件 | iOS | Android |
|---|---|---|
| 权限卡 | 有：`等待授权` y 135.3 + `要跑一条命令,可以吗?` + 蓝色 `允许一次`（y 193.3–241.0, h 48.0）+ `拒绝` | **无** |
| 审批问题卡 | 有：`两个失败的用例怎么处理?`（y 614.3）+ 编号选项 + `1/1` + `跳过`/`提交` | **无** |
| 工具行 | `已调用工具` 折叠头 y 430.3 + 2 行 `工具调用 · 42 行` | 1 行 `工具调用 · screenshot-capture · ok · 10 张` y 624.3 |
| 正文 | 3 段（y 371.0–541.3），17 pt | 1 段（y 485.7–519.7），14 sp |
| composer | 帧内无 | 有（y 766.3–868.7） |

## page-chat-assistant

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 时间戳右缘 | x 352.7 | x 368.7 | 16.0 pt |
| 头像/名字 | #81858C，x 38.7 | #9A9AA2，x 21.7 | 色值 + 17 pt |
| 工具行 | y 399.7，墨高 12.7 | y 475.0，墨高 12.7 | 扣 chrome 后 Δ10.6 |
| 正文 | y 432.0，墨高 16.7（17 pt） | y 517.0，墨高 13.7（14 sp） | 字号 |
| 代码块 | 有语言标签 + 着色（#22C55E） | 无着色 | 高亮缺失 |

## page-chat-official（已知差异 #3）

| 控件 | iOS | Android |
|---|---|---|
| 富文本 transcript | 代码块 `struct NativeChat`（y 122.0–174.3）、`E=mc²`（210.7）、原始 HTML（247.7）、`[note]`（271.3）、`脚注`（308.7）、**`已编辑 6 个文件` 卡**（393.3–640.0，含 4 行文件 + `+1 −1` + `全部 6 个文件 ⌄`） | **全部没有**；只有 1 条用户气泡 + 1 段正文 |
| 用户气泡 | 无 | `hello test 123` y 531.3，右缘 368.7 |
| 正文 | — | y 612.7–646.0，14 sp |
| composer | y 736.7 起，17 pt | y 772.3 起，14 sp |
| 统计行 | y 780.0，17 pt，带 `○` | y 818.0，14 sp |

差异 = **内容缺失**（样本在 `android/lib/src/androidTest/.../ScreenshotSamples.kt`，本 lane 不可写）。

## page-chat-failed

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 失败呈现 | 最后一泡下 **红字 `not sent`** #C0392B（y 663.0） | 顶部 **橙色横幅** #B45309（y 60.0–73.0，x 4.7–391.0） | 完全不同的组件 |
| 气泡 | y 545.0 / 570.7（灰） | y 485.7 / 506.7 | — |
| 正文 | 17 pt | 14 sp | 字号 |

## page-chat-queued

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| `排队中` 条 | composer 上方 y 705.0（`#61656A`） | **无**（注册表：sample 未填 `ComposerState.queued`） | 缺失 |
| 排队徽标 | 气泡右下 y 616.7 `#66666B` | 无 | 缺失 |
| 时间戳右缘 | 352.7 | 368.7 | 16.0 |

## page-chat-long

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 内容起点 | y 393.0（蓝链接） | y 82.3 | 两边**滚动位置不同**，逐行不可比 |
| 正文行距 | 24.0（456.3→480.3） | 20.7（186.7→207.0） | 行距 3.3 |
| 正文墨高 | 16.0 | 13.3–15.0 | 字号 17 vs 14 |

## page-chat-draft

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 空态标题 | y 261.7，墨高 15.7 | y 137.0，墨高 16.3 | 扣 chrome 后 Δ2.0 |
| 蓝色主按钮 | y 327.0–376.7，h 50.0，#2F5BFF | y 203.3–251.0，h 48.0，**#3964FE** | 高度 50 vs 48；颜色 accent vs ctaOverride |
| 正文 | 17 pt | 14 sp | 字号 |

## page-chat-permission

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 页面顶栏 | **无**（直接是卡片） | 有（`☰ 新会话 ●未启动 ⋯`，y 14.7–30.7） | Android 多一条顶栏 |
| 卡片底色 | #F5F6F7（浅灰卡） | #F2F3F5（与页面同色） | 卡片不可分辨 |
| `✋` 图标 | 有（x 34.0，与标题同高） | 无 | 缺失 |
| 标题墨高 | 18.7（17 pt 粗） | 16.3（17 sp 粗） | 同字号 |
| CTA `允许一次` | y 327.0–374.7，h 48.0，**#3964FE** | y 394.0–441.7，h 48.0，**#2F5BFF** | **颜色不同**（accent vs ctaOverride） |
| `拒绝` | y 400.3 | y 471.7 | — |
| composer | 无 | 有（y 798.3 起） | Android 多 |

---

# 四、shell / files / workspace-folders（3 张）

## page-shell

| 控件 | iOS | Android（修前） | Android（修后） | 差 |
|---|---|---|---|---|
| 分组标题 `这台手机` | 墨高 15.3（17 pt），x 33.0 | 墨高 11.3（12 sp），x 32.3 | **墨高 16.3** | 修前 −4.0 pt |
| 行 `状态` | 墨高 15.3（17 pt），y 175.0 | 墨高 13.3（14 sp），y 113.7 | **墨高 16.3** | 修前 −2.0 pt |
| 行距 | 52.3（175.0→227.3） | 44.6（113.7→158.3） | 44.7 | **仍差 7.6 pt** |
| 脚注 `这些命令…` | 墨高 12.7，y 333.7 | 墨高 13.3，y 247.3 | 13.3 | 0 |
| 空态图标 | 55.0×43.3，圆角框 #808080 | 43.7×44.0，#9A9AA2 | 同左 | 宽 11.3、颜色偏浅 |
| 空态标题 `还没接上命令` | 墨高 19.7（≈20 pt 粗） | 墨高 16.3（17 sp 粗） | 16.3 | **19.7 vs 16.3**：无 20 pt token，未改 |
| 空态说明 | 17 pt，折两行（y 528.3 / 548.3） | 13 sp，一行（y 456.7） | 13.3 | 字号导致换行不同 |

## page-files

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 大标题 `手机工作区` | 34 pt，y 376（sheet 125.3–155.3 pt） | 17 sp 粗体，y 14.7–30.7 | **没有 34 pt 大标题** |
| 3D 入口 | 右上白圆 + 立方体图标，x 353.0–374.3，y 72.3–96.3 | **无** | 缺失（= `3D 示例` sheet 的入口） |
| 搜索框 | 灰底胶囊，y 167–190，放大镜 + 17 pt 占位 | 灰底胶囊，y 60.7–81.0，放大镜 + 17 sp 占位 | 扣 chrome 后 Δ0.4；高度 23 vs 20.3 |
| 空态标题 | y 269.7，墨高 15.7 | y 127.0，墨高 16.3 | 扣 chrome 后 Δ7.0 |
| 空态说明 | 17 pt（墨高 11.7？—— 见 §10） | 13 sp（墨高 12.3） | 待查 |
| 背景 | #FFFFFF | #F2F3F5 | 底色不同 |

## page-workspace-folders

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 大标题 `工作文件夹` | 34 pt，y 125.7–155.3 | 17 sp 粗体，y 14.7–30.7 | **没有 34 pt 大标题** |
| 右上 `添加` | 白色胶囊 y 204–270 | 蓝字 y 14.7–30.7 | 胶囊缺失 |
| 背景 | #FFFFFF | #F2F3F5 | 底色不同 |
| 空态标题 | y 293.3，墨高 15.7 | y 127.0，墨高 16.3 | 扣 chrome 后 Δ7.0 |
| CTA | x 20.0–330.0（w 310），h 50.0，#2F5BFF | x 16.0–381.0（w 365），h 48.0，**#3964FE** | 宽差 55；色 accent vs ctaOverride |

---

# 五、surface（1 张）

## surface-code-block

| 控件 | iOS | Android | 差 |
|---|---|---|---|
| 卡片顶 | y 92.7（首行墨迹 115.7） | y 0.7（首行墨迹 14.3） | **整块上移 92 pt**：Android 无顶部留白 |
| 语法着色 | 关键字蓝 `let` + 字符串 **#22C55E** | 全 #111114（8462→0 个绿像素） | 无高亮 |
| 头部按钮 | 两个：换行图元 + 复制 | 一个：复制 | 缺一个 |
| 头部底色 | #E9E9ED（100,182 px） | 无 banner 底（`codeBanner` 未用） | 缺 banner |
| 代码字号 | 墨高 12.7（12 pt mono） | 墨高 9.0（12 sp mono，Latin 墨高天然更矮） | 不可比（同字号） |

---

# 六、env-home（补上的那一条）

| 控件 | iOS | Android（2026-11-02 采集） |
|---|---|---|
| 帧 | 1206×2622 | 1206×2622 |
| 语言 | 中文（地图 / 日历 / 照片 / 设置） | 英文（Mon, Nov 2 / Gmail / Photos / YouTube） |
| 状态栏 | 09:41 + 灵动岛 + 信号/wifi/电池 | 1:03 + 3G + 信号 + 电池，无灵动岛 |
| 小组件 | 有：地图 2×2、日历 2×2（`今天无日程`） | 无 |
| 图标网格 | 4×2 + 2 dock | 3 + 4 dock |
| 搜索 | 底部胶囊 `搜索` | 底部 Google pill |
| 壁纸 | 蓝绿抽象 | 深蓝渐变 |
| 手势条 | 无（iOS home indicator 不在图内） | 有 |

两边是**两个不同操作系统的桌面**，逐项对齐没有意义；这张图的作用是证明 Android 侧真的
跑在 402×874 pt @3× 的同一帧上。它不进 `parity` 基线（注册表仍是 `pending`）。

---

# 七、修了什么（修前 → 修后）

| # | 文件 | 改动 | 修前 | 修后 | 依据 |
|---|---|---|---|---|---|
| 1 | `ui/SettingsMetrics.kt` | `SECTION_GAP_PT 38.67f → 35f` | Android 卡间距 38.7 pt；第 4 张卡比 iOS 低 11.3 pt | 35.0 pt；4 张卡顶 y = 140.7 / 280.3 / 524.7 / 769.0，iOS−61.3 = 140.7 / 280.4 / 524.7 / 769.0，**Δ ≤ 0.1 pt** | `ios-settings.png` 4 条灰带 105 px（920→1024、1653→1757、2386→2490）；原注释引用的 914/1030、116 px 在该文件里不存在 |
| 2 | `ui/surface/SettingsChrome.kt` + `ui/page/SettingsPage.kt` | `SettingsRowFrame` 新增 `trailingInset`，开关行传 `SWITCH_TRAILING_INSET_PT`(14) | 开关 x 283.7–346.3（离卡右缘 39.3） | x 309.0–371.7（离卡右缘 13.6） | iOS 开关 x 309.0–371.7，卡右缘 385.3 → 14.0 pt |
| 3 | `ui/page/SessionsPage.kt` | `▢` 文本字符 → `Canvas` 画的 `bubble.left`（17 pt 框内，描边 8.5%） | 墨迹 9.7×10.3，空心方块 | 墨迹 17.0×15.7，x 24.0–40.7 | iOS `bubble.left` 墨迹 16.0×15.3，x 24.3–40.0（`SessionsPage.swift:549`） |
| 4 | `ui/surface/SettingsChrome.kt` + `ui/page/WebSearchSettingsPage.kt` | 新增 `SettingsBodyRow`（17 pt），`还要知道` 三段改用它 | 墨高 13.3（13 sp），行距 16.3 | 墨高 17.7，行距 20.3 | iOS 同一字符串墨高 16.7，行距 22.3；Swift 三段是裸 `Text`（`.body` 17），同页其余行显式 `.font(.system(size: 13))` |
| 5 | `ui/page/PDSHShellPage.kt` | 分组标题 `caption(12) → rowLabel(17)`；行标签/值 `body(14) → rowLabel(17)` | 墨高 11.3 / 13.3 | 墨高 16.3 / 16.3 | `ios-shell.png` 同一字符串墨高 15.3 / 15.3（17 pt） |

**回归证据**：改完在同一台 AVD 上重跑 `--profile ios-parity`（对比模式），26 个状态里
**18 个 0 diff px**，其余 8 个是本次改动的页面（settings-default 9.38%、shell 6.12%、
settings-about 4.88%、settings-search 3.54%、sessions-many 0.38%、settings-model 0.13%、
sessions-ungrouped 0.10%、sessions-error 0.07%）。0 diff 的 18 个证明模拟器能逐字节复现原基线，
8 个的差异就是改动本身。

---

# 八、改不了的（缺 token / 需要 iOS 那边改 / 结构性）

1. **开关绿 vs 蓝**。iOS #34C759（systemGreen）；Android #3964FE（accent token）。
   `spec/ui/v1/tokens.json` 里没有开关色：`colors.success` 是 **#27865A**，不是 #34C759。
   造一个新 token 不是本 lane 能做的，所以**没改**。
2. **正文 14 vs 17**（8 张 chat 全部命中）。这不是 Android 用错 token：
   `typography.body.baseSize = 14`，而 iOS 渲染的是 `.font(.body)` = 17
   （`ChatPage.swift:4010`），`NativeParityTokens.bodySize = 14` 只用于 `NativeTurnProcessRow` 等。
   **token 与基线互相矛盾**，改 Android 只是让一边服从另一边。需要 token 侧裁决。
3. **纯黑 vs #111114**。iOS 的 settings/shell/sessions 文字实测 #000000（系统 `.primary`），
   token `colors.primary = #111114`。Android 跟 token，所以差 17/255。
   要么 iOS 改用主题色，要么 token 承认 `.primary`。
4. **iOS 用系统色，token 用一个值**：`#8A8A8E`(secondaryLabel) vs token `#66666B`；
   `#0088FF`(systemBlue) vs token `#3964FE`。同一页里两种蓝都存在（`启动本地引擎` 是 #0088FF，
   而 `完成` 是 #3964FE）—— 需要先把「哪些页用系统色」定下来。
5. **ctaOverride 用错层**：`page-chat-permission`、`page-chat-draft`、`page-workspace-folders`
   的 iOS 主按钮实测是 **#3964FE**（accent），Android 用 **#2F5BFF**（ctaOverride）。
   token 自己的注记说 ctaOverride 是「审批卡 CTA 的页面层固定色」，但基线在审批卡上画的是 accent。
   改哪一边都要先决定 token 的意图，**没改**。
6. **没有白色 bar / 胶囊的 token**：iOS settings/schedules/files/workspace 的顶栏是 #FFFFFF，
   `colors.background` 是 `null`（未测量），`colors.input` 是 #FFFFFF 但语义是输入框。
   胶囊按钮（`完成`/`添加`/`新建`/`↻`）需要圆角 + 阴影 + 白底三个值，一个都没有。
7. **没有 20 pt 字号的 token**：`ios-shell.png` 的空态标题是 20 pt（墨高 19.7），
   `typography` 只有 17（headline/rowLabel）和 15（subheadline）。Android 停在 17。
8. **行高 52.33 vs 44**：iOS `pageRowMinHeight` 实际行高 52.3；`geometry.pageRowMinHeight = 44`
   是下限而不是行高。没有「行高」token。
9. **语法高亮没有颜色 token**：iOS 代码块字符串 **#22C55E**、关键字蓝；tokens 里没有 code 语法色。
   Android 全单色 #111114。
10. **Material 默认色泄漏**：`page-settings-network` 里有 **#E6E0E9**（Material3 的 surface tint）
    8584 px，不是任何 token；`#9A9AA2` 61205 px 是 tertiary token 被大面积使用。
11. **结构性（页面本身就是两个东西）**：
    - `settings-runtime`：iOS 5 块 vs Android 8 个折叠段，标题也不同（运行状态 / 运行时详情）。
    - `settings-about`：iOS 1 张卡 vs Android 3 张（版本/系统/更多）+ 折叠头。
    - `settings-plugins`：iOS 三个玻璃胶囊 + 告警条 + 图标行 vs Android 纯文字链接、无刷新。
    - `settings-model`：iOS 独立 sheet（无 picker）vs Android shell 内嵌（有 picker）。
    - `settings-network`：iOS 单行 52.33 pt 列表 vs Android 两行 35 pt + 行尾 `⋯`。
    - `sessions`：iOS 满宽 402 pt vs Android 320 pt 抽屉（CTA 窄 82 pt，空态居中偏左 41.2 pt）。
    - `chat-official / chat-failed / chat-queued / chat-default`：transcript 与失败/排队组件内容不同，
      样本在 `android/lib/src/androidTest/**`（本 lane 不可写）。
    - `page-files`：iOS 的 `3D 示例` sheet 与它的 `完成` 在 Android 没有对应物（见 §9）。

---

# 九、「门禁绿但实际不对齐」——找到 7 处

1. **`files` 的 `3D 示例`：源码里有、运行时永远不渲染，检查器算它存在。**
   `FilesPage.kt:478-483` 的入口被 `if (onOpenDemo != null)` 包着，而 `PdshNavHost.kt` 的
   `FilesRoute` **从不传** `onOpenDemo`。`page_structure_check.py` 按源码标签配对，于是
   `3D 示例` 被记为「已有」，`--verbose` 里 files 只报 `完成` 一条 missing。
   像素证据：Android 面板右上角**没有**立方体按钮，iOS 有（x 353.0–374.3，y 72.3–96.3）。
   这正是 `files / 完成` 那条老故事的下一层：注册表记的是 **sheet 的取消键**，
   而真正缺的是**入口 + sheet 本身**；入口因为静态存在而被门禁放过。
2. **页面标题从不比较。** 契约里有 `title.text`，检查器只比 sections 和 actions。三张图上的
   标题不同而门禁全绿：`runtime-details` 运行状态 → 运行时详情；
   `native-configuration` 插件 → 本会话设置；`egress-allow-list` 网络访问 → 出网白名单。
3. **`page-sessions-default` 与 `page-sessions-nothing` 共用一张 Android 图**
   （md5 `64dcaccb…`），两张 iOS 图不同。27 个状态里有 1 个是「一图顶两态」，
   registry 却把两个都记成 `captured`。
4. **`chat`：契约 67 个 action / Android 29 个 label，divergences 0。**
   `page_structure_check.py` 的摘要行自己印出这两个数字，然后判绿。
5. **`settings-plugins` 的「插件」**：iOS 的插件 tab 是一整页（胶囊 + 告警 + 图标行），
   Android 的插件 tab 渲染的是**另一页**（本会话设置）。检查器按 section/action 配对，
   而 tab 选择器里那个 `插件` 恰好让页面看起来「叫对了」。
6. **`settings-model`**：注册表写「两边都是 模型 tab」，但 iOS 图上**没有分段选择器**，
   是独立 sheet。门禁不比容器。
7. **`egress-allow-list`**：契约 7 个 action / Android 7 个 label，`divergences 0`；
   但图上 Android 每行多一个 `⋯` 菜单、iOS 没有，且行高 35 vs 52.33。标签数量相等 ≠ 控件相同。

另外一条不是「绿但不齐」而是**红得没意义**：`page_structure_check.py` 的 `actions` 汇总里，
`files` 是 `contract 6 / android 2 / divergences 1` —— 6 个动作只核了 1 个，
另外 4 个落在「baseline 打不开的 presentation」里被跳过。数字看着像覆盖率，其实不是。

---

# 十、open questions

1. `ios-settings.png` 的卡片间距到底是 35.0 还是 35.33？灰带 105 px，卡到卡 106 px。
   我按「灰带 = 布局间距」取了 35.0；若 Android 该画 106 px，需要 +0.33。
2. `SECTION_GAP_PT` 原注释的 116 px 从哪来？`settings-chat.png` 实测也是 105 px。
   是抄错了文件，还是曾经有过另一版 iOS 布局？
3. 会话行 56.7 vs 56.0 的 +0.7 pt 来自哪里？行是 `heightIn(min=56)`，多出的 2 px 可能是
   分隔线占位。要不要把分隔线改成叠加（overlay）？
4. token `body=14` 与 iOS `.body`=17 的矛盾，以哪边为准？影响 8 张 chat 图。
5. `ctaOverride` 的适用面：基线在审批卡上画 accent（#3964FE），token 说页面层固定 #2F5BFF。
   是 token 注记过时，还是 iOS 那张图是旧版？
6. 是否要引入图标依赖（`material-icons`）或资源管线？现在 `:lib` 没有任何图标，全部用字符画；
   `bubble.left` 只能用 Canvas 近似。
7. `env-home` 要不要进 `parity` 基线？我让它留在 `pending`，从
   `docs/receipts/ui-parity-sheet/adb/` 配对（见 §11），因为桌面截图不是页面基线。
8. `page-files` 空态说明的字号：iOS 墨高 11.7 对 17 pt 偏小、对 13 pt 偏大，
   需要在 iOS 端确认 `ContentUnavailableView` 实际用的 role。

---

# 十一、重采后的图在哪

| 东西 | 路径 | 数量 |
|---|---|---|
| 并排图（27 张，含 env-home） | `docs/receipts/ui-parity-sheet/*__ios-left.png` | 27 |
| 索引（含 `source` 列） | `docs/receipts/ui-parity-sheet/metrics.txt` | 1 |
| Android 重采基线（设备写） | `android/lib/src/test/resources/screenshots/ios-parity/*.png` | 26 |
| env-home 的 adb 采集 | `docs/receipts/ui-parity-sheet/adb/env-home.png` | 1 |
| 本次逐张差异 | `docs/receipts/ui-parity-sheet/DIFFS.md` | 1 |

重采环境：自建 AVD `pdsh-l64-5728`（android-35 / google_apis / arm64-v8a），
端口 **5728**，`-no-window`，en-US，`font_scale 1.0`，`wm size 1206x2622` + `wm density 480`，
API 35。未触碰 5556 / 5558 / 5670–5726。用完删除。

复现命令：

```bash
bash android/tools/screenshot-capture.sh --profile ios-parity            # 对比模式（应当全 0 diff）
bash android/tools/screenshot-capture.sh --profile ios-parity --update   # 重写 26 张基线
python3 android/tools/ui-parity-sheet.py                                 # 重铺 27 张并排图
```

---

# 十二、L75 复核（2026-11-02）：files / workspace-folders 与 3D 入口

本节的数全部由本车道在自建 AVD `pdsh35` 上重采后**重新量**（不是抄 §四 的旧数）。
量法同 §一：`pt = px / 3`，逐行非背景墨迹带；脚本是一次性的 `/tmp/measure.py`（不进仓库）。

## 12.1 先说结论

| 项 | 修前（§四 的记载） | 修后（本次实测） |
|---|---|---|
| files 大标题 | 17 sp 粗，ink y 14.67–30.67 | **34 pt**，ink y 68.00–100.33（h 32.67） |
| files 背景 | #F2F3F5 | **#FFFFFF**（`colors.page`） |
| files 的 `3D 示例` 入口 | L67 说「真实现了」，L64 说「源码有、运行时不渲染」 | **设备上确实出现**：黑色立方体 ink x 353.33–372.33、y 10.67–32.67，白圆 x 338.33–388.67（含阴影） |
| workspace-folders 大标题 | 17 sp 粗 | **34 pt**，ink y 67.67–100.33 |
| workspace-folders 的 `添加` | 蓝字 y 14.67–30.67 | **白胶囊**：ink #2F5BFF x 331.00–362.00，胶囊 x 313.33–388.67（含阴影），h 44 |
| workspace-folders CTA | x 16.0–381.0（w 365）h 48 #3964FE | x 32.00–369.67（**w 338，与 iOS 逐像素同**）h 44 #2F5BFF |
| surface-code-block | 卡片顶 0.7；着色 0 | **未改**：卡片顶 0（采样布局不属本车道）、着色已在（L67 的 `CodeHighlighter` 真的在跑）——见 12.4 |

## 12.2 page-files：逐条（iOS 减 57.33 = chrome 偏移，取大标题为锚）

| 控件 | iOS | Android（L75 后） | iOS−57.33 | Δ |
|---|---|---|---|---|
| 大标题 `手机工作区` | 125.33–155.33 | 68.00–100.33 | 68.00 | **0.00（锚）** |
| 搜索胶囊 | 169.00–212.67（h 44.00，x 16.00–385.67） | 112.00–155.67（h 44.00，x 16.00–385.67） | 111.67 | **+0.33** |
| 空态标题 `还没有文件` | 269.33–285.00 | 213.67–230.00 | 212.00 | **+1.67** |
| 空态说明 | 297.00–309.00 | 243.33–255.67 | 239.67 | **+3.66** |
| 3D 立方体 ink | x 353.00–374.33（21.33 宽） | x 353.33–372.33（19.00 宽） | — | 左缘 +0.33、宽 −2.33 |
| 3D 胶囊 | x 333.33–393.00（含阴影 w 60.00） | x 338.33–388.67（含阴影 w 50.67） | — | 阴影晕小 9.33（`pageBarButtonElevation` 未实测，见 §13） |
| 返回 `‹` | **无** | x 22.67 起 | — | Android 多一个（组件是 push 进来的，iOS 这张是根） |

## 12.3 page-workspace-folders：逐条（iOS 减 57.66）

| 控件 | iOS | Android（L75 后） | iOS−57.66 | Δ |
|---|---|---|---|---|
| 大标题 `工作文件夹` | 125.33–155.33 | 67.67–100.33 | 67.67 | **0.00（锚）** |
| `添加` ink | x 336.67–367.67（w 31.33），y 77.00–91.67 | x 331.00–362.00（w 31.00），y 15.33–30.33 | y 19.34 | 左缘 −5.67、y −4.01 |
| `添加` 胶囊 | x 302.67–393.00（含阴影 w 90.67） | x 313.33–388.67（含阴影 w 75.67） | — | 阴影晕小 15 |
| 空态标题 | 194.33–210.00 | 135.67–152.00 | 136.67 | **−1.00** |
| 空态说明 | 222.00–234.00 | 164.33–177.00 | 164.34 | **−0.01** |
| CTA `添加工作文件夹` | 252.00–301.67（h 50.00），x 32.00–369.67，w 338.00，#2F5BFF | 191.33–235.00（h 44.00），x 32.00–369.67，w 338.00，#2F5BFF | 194.34 | 位置 **−3.01**、**高 −6.00** |
| 返回 `‹` | 无 | 有 | — | 同 files |

**CTA 高度是唯一剩下的硬差**：iOS 50，Android 44（`geometry.pageRowMinHeight`）。
`geometry.pageCtaHeight = 50` 本轮加过又撤了：`PageGeometryTokenTest` 要求每个页面级
几何 token 至少被**两个** page 文件读，而只有 workspace-folders 有 CTA（files 没有），
撤掉比留一个「一个用户」的 spec 条目诚实。要么给它第二个用户，要么让 files 也有 CTA。

## 12.4 surface-code-block：核了，但没改

| 项 | iOS（`ios-code-block.png` 实测） | Android | 判定 |
|---|---|---|---|
| 卡片顶 | y 104.00 | y 0.00 | **采样布局的锅**：`CodeBlock` 在 `ScreenshotSamples`/`ChatParityScreenshotTest.surfaceCodeBlock` 里被放在页面顶部。这两个文件是 L70 的 `android/tools/acceptance/**` 与 androidTest，不在本车道可写面 |
| 卡片高 | 155.67 | 133.33 | 样本正文行数不同，不可比 |
| 语法着色 | 字符串绿 `#22C55E` | **有**：`highlightCode()` 在 `CodeBlock.kt:114`，四类 ink 全取自 token | L67 的说法成立 |
| header 底 | `#E9E9ED` | **有**：`tokens.colors.codeBanner`，`CodeBlock.kt:75` | 成立 |
| header 按钮 | 两个（换行 28×28 + 复制 44×28） | **一个**（复制） | **真差**：`DSSCodeBlock`(`Components.swift:151`–`200`) 的换行开关与 `已复制` 反馈、`展开全部 N 行` 尾部都没搬。本车道没做（见 §14 open question 1） |

## 12.5 重采「对比数字」怎么读

`bash android/tools/screenshot-capture.sh --profile ios-parity --states …` 比的是
**Android 对自己的旧基线**，所以改完必然红：

| state | diff px | 占比 | 含义 |
|---|---|---|---|
| page-files | 322423 | 10.1964 % | 大标题 + 白底 + 立方体入口本身就是这几块像素 |
| page-workspace-folders | 313072 | 9.9007 % | 大标题 + 白胶囊 + CTA 位置 |
| surface-code-block | 20033 | 0.6335 % | 未改动；差异来自本轮**没有**重写它，属上轮遗留（L67 之后的基线漂移） |

**没有跑 `--update` / `--write-baseline`**：26 张 Android 基线仍是 L64/L67 那批，
本轮只重铺了 3 张并排图（`page-files`、`page-workspace-folders`、`surface-code-block`，
其中 code-block 的并排图逐字节未变），`metrics.txt` 只改了三行 `dw/dh`。

重采环境：AVD `pdsh35`（android-35 / arm64-v8a），端口 **5746**，`-no-window -read-only`，
未触碰 5556 / 5558 / 5670–5744。

## 12.6 本轮新增的 token（`spec/ui/v1/tokens.json`，只增）

| token | 值 | 依据 |
|---|---|---|
| `colors.page` | #FFFFFF / #000000 | `NativePagePalette.page`(`Components.swift:244`)，`FilesPage.swift:55` 显式铺它 |
| `colors.taskScreen` | #000000 / #000000 | 任务屏纯黑（`TaskScreenPage.swift:66` 的 `TaskScreen`，引擎不读主题） |
| `geometry.pageBarButtonInsetH` | 22 | `ios-workspace-folders.png` 的 添加 胶囊（钮 77.7 = 34 文字盒 + 2×22） |
| `geometry.pageBarButtonElevation` | 2 | **未实测**：PNG 只能证明白胶囊白底上有一圈阴影，blur/alpha 量不出 |

`colors.page` 配了对比度对 `systemLabel/page`（21:1），`colors.taskScreen` 配了
`onAccent/taskScreen`（21:1）；`ui_check.py` 除 README 行数外全绿。

---

# 十三、L73 复核（2026-11-02）：sessions 家族（列表 + 会话内容显示）

量法与 §一 相同（`pt = px / 3`，逐行非背景墨迹带）。本节所有 Android 数字都来自本车道
在自建 AVD `pdsh-l73`（端口 **5756**，android-35 / google_apis / arm64-v8a，`-no-window`，
用完删除；未触碰 5556 / 5558 / 5736 / 5738 / 5746）上**重采之后**的
`android/lib/src/test/resources/screenshots/ios-parity/page-sessions-*.png`。
chrome 锚点：会话抽屉这一组用搜索占位墨迹对齐（iOS 130.3 / Android 66.7 → **扣 63.6**）。

## 13.1 结论先行

| 项 | 修前 | 修后 |
|---|---|---|
| `page-sessions-default` 与 `page-sessions-nothing` | **同一张 PNG**（md5 `64dcaccb…`） | 两张不同的 PNG（`6e98bb5b…` / `cce3f5ac…`，互差 **79,620 px**；iOS 两张互差 74,794 px） |
| 列表宽度 | 页面自己钉死 320（`SessionsMetrics.drawerWidth`） | 页面填满容器；320 是**容器**的事（`NativeShell.swift:97`/`:875`） |
| `＋新建会话` 下分隔线 | x 16.0–303.7（跟着 320 走） | **x 57.0–344.7**（`.frame(width: 288)` + `.overlay(.bottom)` 居中；iOS 57.0–344.7） |
| 空态 CTA（default / 402 全窗） | x 16.0–303.7（宽 288） | **x 16.0–385.7（宽 370）**，与 iOS 逐点相同 |
| 空态标题中心（default） | 159.7 | **200.5**（iOS 200.65） |
| 会话行行距 | 56.7 | **56.0**（20 行累积差 14 pt → 0） |
| 会话行前导气泡 | 17.0 × 15.7 | **16.3 × 15.3**（iOS 16.3 × 15.3） |
| 工作文件夹 `⋯` | `…` 9.3 × 2.3，x 279.0–288.0 | **三点 18.3 × 4.0，x 279.0–297.0**（iOS 18.3 × 4.0，x 279.0–297.0） |
| 顶部 `‹` 返回键 | 有（x 22.7–25.3，y 20.0–25.3） | **无**（七张 iOS 基线都没有这个控件） |
| 失败行颜色 | #C0392B | #C0392B（**两边本来就是同一个值**，见 13.6） |
| 失败行 `✕` | 有（宿主传了 `onDismissFailure`） | **无**（基线只有 `Text(errorText)` + `重试`） |
| 会话行按下反馈 | 平台 ripple | 基线的一层 #F2F3F5、圆角 12、150 ms 渐入 |

## 13.2 为什么 `default` 和 `nothing` 在 iOS 是两张图

**不是两个页面状态，是同一个状态的两个容器宽度。** 逐条证据：

| 证据 | iOS `sessions`（default） | iOS `sessions.nothing` |
|---|---|---|
| 路由 | `NativeShell.swift:842` `SessionsPage(onSelect:)` 直接挂在 402 pt 窗口 | `NativeShell.swift:875` `DrawerPreview`，`.frame(width: 320)` |
| 空态标题墨迹 | x 134.3–267.0（中心 **200.65**） | x 93.3–226.0（中心 **159.65**） |
| 空态说明墨迹 | x 90.0–304.0 | x 49.0–263.0 |
| CTA | y 348.7–398.3，x 16.0–**385.7**（宽 370） | 同 y，x 16.0–**303.7**（宽 288） |
| `＋新建会话` 分隔线 | y 223.7，x **57.0–344.7** | y 223.7，x **16.0–303.7** |
| 其余（状态栏、搜索、新建行、阻塞句） | 完全相同 | 完全相同 |

两张 iOS 图的 74,794 px 差异全部落在 y 223.7–398.3 pt 这四段里；**没有一句文案不同**
（旧 registry note 说「一个显示 会话 分组标题、另一个不显示」是错的：两张都**没有**该标题，
两边的墨迹带都在 130.3–146.7 / 194.3–210.0 / 250.3–263.0，逐条相同）。

Android 修前把列表用 `.width(SessionsMetrics.drawerWidth)` 钉在 320，所以两个状态只能是同一帧。
修后页面填满容器，重采时 `default` 装在全窗、其余五态装进 320 抽屉
（`SessionsParityScreenshotTest.captureSessions(drawer = …)`；capture 节点仍是整帧 1206×2622，
所以并排图的 Δ 栏依旧是 0）。

**修后 Android 两张图的差异带（79,620 px）**：

| 带 | Android | iOS |
|---|---|---|
| y 52.0–95.7（搜索胶囊右缘） | x 283.3–385.7 | 无明显带（iOS 那颗是白底 + 阴影，描边不可见） |
| y 171.3（新建行分隔线） | x 16.0–344.7 | y 223.7，x 16.0–344.7 |
| y 224.3–240.7（空态标题） | x 92.0–268.0 | y 283.0–298.7，x 93.3–267.0 |
| y 256.0–269.7（空态说明） | x 48.3–304.7 | y 310.7–323.3，x 49.0–304.0 |
| y 303.0–352.7（CTA） | x 101.0–385.7 | y 348.7–398.3，x 101.3–385.7 |

唯一 Android 独有的第 5 条带是搜索胶囊的 1 px 描边（`colors.borderLight`）：iOS 用阴影不用描边，
这是 §一 已记的「没有阴影 token」老问题，本车道没有可指的一行去改。

## 13.3 逐条：`page-sessions-default`（402 全窗）

| 控件 | iOS | Android 修前 | Android 修后 | 修后 Δ（扣 63.6） |
|---|---|---|---|---|
| `‹` 返回键 | **无** | x 22.7–25.3，y 20.0–25.3 | **无** | 0 |
| 搜索胶囊 | x 16.0–385.7（白底 + 阴影 + 🔍） | x 16.0–385.7（1 px 描边，无 🔍） | 同修前 | 0（🔍 仍缺：`:lib` 无图标集） |
| `＋新建会话` 墨迹 | y 194.3–210.0，x 18.3–111.0 | y 142.7–158.7，x 16.7–102.7 | 同修前 | y **+12.4**，x −1.6（`+` 是 17 sp 字符，iOS 是 20 pt SF Symbol） |
| 其下分隔线 | y 223.7–224.0，x 57.0–344.7 | y 172.0–172.3，x 16.0–303.7 | y 171.3–171.7，x **57.0–344.7** | 形状 0；y **+11.6** |
| `先启动本地引擎,才能新建会话。` | y 250.3–263.0 | y 188.7–202.0 | y 188.0–201.3 | **+1.7** |
| `还没有工作文件夹` | y 283.3–298.7，x 134.3–267.0 | y 225.0–241.3，x 92.0–227.0 | y 224.3–240.7，x **133.0–268.0** | x 中心 **−0.15**；y **+5.0** |
| `选一个文件夹,会话和文件都放在里面。` | y 310.7–323.3，x 90.0–304.0 | y 256.7–270.3，x 48.3–263.7 | y 256.0–269.7，x **89.3–304.7** | x 中心 **+0.0**；y **+9.3** |
| CTA `新建工作文件夹` | y 348.7–398.3，x 16.0–385.7，h 50.0，#2F5BFF，r 12 | y 303.7–353.3，x 16.0–**303.7** | y 303.0–352.7，x 16.0–**385.7** | **宽度 0**；y **+18.3** |

## 13.4 逐条：`page-sessions-nothing`（320 抽屉）

| 控件 | iOS | Android 修后 | Δ（扣 63.6） |
|---|---|---|---|
| 空态标题中心 | 159.65 | 159.5 | −0.15 |
| 空态说明 | x 49.0–263.0 | x 48.3–263.7 | 中心 0 |
| CTA | x 16.0–303.7 | x 16.0–303.7 | **0** |
| 新建行分隔线 | x 16.0–303.7 | x 16.0–303.7 | **0** |

y 值与 default 是同一套（两态只差宽度），所以 13.3 的纵向 Δ 在这里逐条相同。

## 13.5 逐条：`page-sessions-many` / `page-sessions-empty` / `page-sessions-ungrouped` / `page-sessions-error`

| 控件 | iOS | Android 修前 | Android 修后 |
|---|---|---|---|
| 会话行行距 | **56.0**（分隔线 388.7 / 444.7 / 500.7 …） | **56.7**（308.3 / 365.0 / 421.7 …） | **56.0**（307.0 / 363.0 / 419.0 / 475.0 …） |
| 行分隔线 x | 16.0–303.7 | 16.0–303.7 | 16.0–303.7 |
| 前导气泡墨迹 | x 24.3–40.3，y 353.3–368.3（16.3 × 15.3） | x 24.0–40.7，y 273.0–288.3（17.0 × 15.7） | x **24.3–40.3**，y 272.0–287.3（**16.3 × 15.3**，跨度 15.3 对 iOS 15.0） |
| 行标题 x | 51.0 起 | 51.7 起 | 51.7 起（raster 差） |
| 分组行 `项目资料 · 20 个会话` | y 299.3–314.7 | y 222.3–238.3（扣 chrome 后 **−13.4**） | 同修前（见 13.8） |
| 分组行 `•••` / `⋯` | `•••` x 279.0–297.0（18.3 × 4.0） | `…` x 279.0–288.0（9.3 × 2.3） | 三点 x **279.0–297.0**（**18.3 × 4.0**） |
| 分组行 chevron 墨迹 | x 17.3 起（`chevron.down` 12 pt semibold） | x 18.7 起（`›` 旋转 90°） | 同修前 |
| 文件夹空态标题 / 说明 / 其下分隔线 | y 374.3 / 402.0 / 438.0 | y 280.7 / 312.0 / **335.0** | y 280.7 / 312.0 / 335.0（分隔线改成 overlay，不再占 0.5 pt 高度） |
| `还没有会话` 与分组行之间 | 59.6 | 42.3 | 42.3（List 行内边距，见 13.8） |
| 失败行 | `读不到会话` + `重试`（#C0392B / 蓝） | 同文案，色 #C0392B，**多一个 `✕`**（仅当宿主传 `onDismissFailure`） | **无 `✕`**；色与文案不变 |
| 失败行红字墨迹 | y 301.0–312.3，x 16.3–79.3 | y 226.3–238.3，x 16.7–80.0 | y 225.7–237.7，x 16.7–80.0 |

## 13.6 失败行颜色：L64 的记载不成立

L64 写「iOS 用系统红 / Android #C0392B」。实测两边**都是 #C0392B（192,57,43）**：

* `ios-sessions-error.png` 的红色墨迹最小 1/12 中位色 = `(192,57,43)`；
* `page-sessions-error.png` 同法 = `(192,57,43)`；
* 源码：`SessionsPage.swift:182` `.foregroundStyle(NativePagePalette.danger)` →
  `Components.swift:255` `danger = 0xC0392B`；Android `colors.danger.light = #C0392B`。
  同一个值，同一行出处。**所以这一项没有可改的东西**，L64 那条是被截图里别的红色（比如 `#C0392B`
  与 `#FF3B30` 的肉眼混淆）带偏了。

## 13.7 空回调审计（本页，逐条）

`SessionsPage.kt` 的签名里 `= {}` 的参数共 **21 个**（其中 3 个是 legacy 的 session-delete），
另有 4 个可空 `= null`（`onRetry` / `onDismissFailure` / `onBack` / `onRefresh`）。逐个判断：

| 参数 | 基线要求 | host 现状（`HostSessionsScreen.kt` / `PdshNavHost.SessionsRoute`） | 结论 |
|---|---|---|---|
| `onSelect` / `onNewSession` / `onRenameStart` / `onRenameDraftChange` / `onRenameCommit` / `onRenameCancel` | 有（`:545` `:141` `:586` `:397-402`） | 两个 host 都真实现（select→`openChatSession`、new→`newChatSession`、rename→`renameChatSession`） | **已接通** |
| `onToggleWorkspace` / `onWorkspaceMenuToggle` | 有（`:420` `:446`） | 两个 host 都实现（本地 fold / 菜单） | **已接通** |
| `onAddWorkspace` / `onWorkspaceDraftChange` / `onCreateWorkspace` / `onCancelCreateWorkspace` / `onRenameWorkspaceStart` / `onRenameWorkspaceCommit` / `onRenameWorkspaceCancel` / `onDeleteWorkspaceRequest` / `onDeleteWorkspaceConfirm` / `onDeleteWorkspaceCancel` | 有（`:268` `:370` `:404` `:358`） | `HostSessionsScreen` 实现（打开编辑器 + 真动作交给 `sessionHandOff` → 「宿主未实现：…」）；`SessionsRoute` **一点没传**（全走默认空 lambda） | **页面侧已接通；宿主侧两处缺口见 §13.11** |
| `onToggleArchived` / `onRestoreArchived` / `onSessionMenuToggle` / `onArchiveSession` / `onNewSessionInWorkspace` | 有（`:305` `:607` `:585` `:588` `:447`） | `HostSessionsScreen`：fold/menu 真实现；restore/archive/new-in-workspace 走 handOff（提示「宿主未实现」）；`SessionsRoute` 全默认 | 同上 |
| `onDeleteRequest/Confirm/Cancel` | **没有**（基线只有归档，`:587` 的注释明说引擎没有删除） | 没人用（只有三个截图测试传 `{}` 保持签名兼容） | **不是基线控件，页面从不渲染**；参数只能等 app/截图套件同步删（本车道不可写） |
| `onDismissFailure` | **没有**（`:176-197` 只有 `重试`） | app 传了 `engine.clearSessionsFailure()` | **已停画**（`✕` 删掉），参数保留给 app 编译，等 app lane 删调用 |
| `onRetry` / `onBack` / `onRefresh` | 有（`:185` `:351`） | app 与 route 都实现 | **已接通**（`onRetry`/`onBack` 可空，缺省就不画控件；`onRefresh` 缺省时 `PullToRefreshBox` 收空 lambda 但手势仍在——见 §13.11 第 2 条） |

「点了没反应」的判定：本页**渲染出来的**每个控件在手上有 callback 时都会调用它；没有 callback 的
（`onRetry`、`onBack`）不渲染。基线没有的控件（`✕`、会话删除）不渲染。

## 13.8 没改的，以及为什么没改

| 项 | iOS | Android | 为什么不动 |
|---|---|---|---|
| 搜索框 → `＋新建会话` 的距离 | 63.6（占位墨迹到标题墨迹） | 76.0 | SwiftUI `List` 的 first-section inset，**`SessionsPage.swift` 里没有一行**画它（`List` 在 `:138`，`.listStyle(.plain)` 在 `:323` 只声明样式，不给数值）。按「指不到行就不要发明」不动；数字留在 §13.11 |
| 分组之间的留白 | 43.7（空态）/ 35 量级 | 25.7 | 同上：`List` 的 section spacing + 每行默认内边距 |
| 分组行 y（`many`） | 299.3 | 222.3（扣 chrome 后 −13.4） | 上面两条的累积结果 |
| 搜索胶囊的 🔍 与阴影 | `magnifyingglass` at x 33.3 + 柔和阴影 | 无图标、1 px 描边 | `:lib` 没有图标依赖、token 表没有阴影；§一 已记 |
| `＋` 字形 | 20 pt SF Symbol（墨迹 x 18.3 起） | 17 sp 字符（x 16.7 起） | 与气泡同一类问题：没有 `plus` 资产；改字号会动行内基线，收益 < 风险 |
| 分组 chevron | `chevron.down`/`chevron.right` 12 pt | `›` 旋转 90° | 同上 |
| 已归档 header 的 chevron / 计数 | `chevron.right` 11 semibold + 计数 13 secondary | `SectionHeader` 共享组件 | 组件在 `SessionPageChrome.kt`，不在本车道可写范围 |

## 13.9 改前 → 改后的像素足迹（重采后与 HEAD 基线逐像素比）

| 状态 | 改前 vs 改后 |
|---|---|
| page-sessions-default | **92,640 px（2.93%）** |
| page-sessions-nothing | **36,992 px（1.17%）** |
| page-sessions-empty | 54,388 px（1.72%） |
| page-sessions-error | 56,374 px（1.78%） |
| page-sessions-many | 162,511 px（5.14%） |
| page-sessions-ungrouped | 58,465 px（1.85%） |

（`many` 最大是因为 20 行行距 56.7 → 56.0 的累积位移；`default` 次之是因为整个空态块换了容器宽度。）

## 13.10 重采与复现

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export ANDROID_SERIAL=emulator-<本车道端口>
bash android/tools/screenshot-capture.sh --profile ios-parity \
  --states page-sessions-default,page-sessions-nothing,page-sessions-empty,page-sessions-many,\
page-sessions-ungrouped,page-sessions-error --update
python3 android/tools/ui-parity-sheet.py
```

环境：自建 AVD `pdsh-l73`（android-35 / google_apis / arm64-v8a），端口 **5756**，`-no-window`，
`wm size 1206x2622` + `wm density 480`，API 35，font_scale 1.0，locale en-US。用完删除。

## 13.11 本节留下的 open questions

1. **搜索框到新建行的 12.4 pt**与**分组留白 18 pt**是 SwiftUI `List` 的量，不是 `SessionsPage.swift`
   的量。要不要在 Android 侧把它们固化成一个「List chrome」常量？（本车道按裁定没做。）
2. `SessionsRoute`（`PdshNavHost.kt`）里 15 个 host 回调**一个都没传**：从路由进入 `会话` 页时，
   点 `＋`、点会话行、`归档`、`恢复`、工作文件夹菜单全是空 lambda —— 这就是「点了没反应」。
   本车道不可写该文件，**接不了**；需要 L69/L72 把 session 写命令接到 `PdshNavFacts`。
3. `HostSessionsScreen` 的 7 个 handOff 手势（新建文件夹 / 重命名文件夹 / 删除文件夹 / 恢复 /
   归档 / 文件夹内新建）仍打印「宿主未实现：…」。**缺什么才能接**：`:app` 里要有 workspace/session
   的写命令（`ChatSessionStore` 现在只有会话的 create/rename/select）。本车道不可写 `:app`。
4. `onDismissFailure` 现在是个不画控件的参数（基线没有关闭键）。等 app lane 删掉
   `HostSessionsScreen.kt:146` 的传参后，可以从签名里删。
5. 会话内容显示（消息正文 / 工具行 / 时间戳 / 产物卡）：`SessionsPage.swift` 里**没有**这些——
   它只有会话行（标题 / 相对时间 / 运行中 / 勾选）、待处理队列页（`:656`，死入口）和四个对话框。
   正文那一套在 `ChatPage.swift`，属 L69 车道（`ChatPage.kt` 本车道不可写）。本车道已把
   **行内**的四项（标题、时间、运行中、勾选）逐条对齐；正文侧需 L69 按 `ChatPage.swift` 复核。


---

# L74（2026-11-02）：settings 家族逐条对齐

本文件的上半部分（L64 原文）保留不动。这一节是 L74 在同一批并排图上的**复核 + 改动**，
每条都能指到 iOS 源码一行。重采环境见 §L74-5。

## L74-1 逐页对照（iOS / Android 修前 / 改法）

### page-settings-default（`SettingsPage.swift`）

| 控件 | iOS | Android | 改法 |
|---|---|---|---|
| 导航条标题 | `通用设置`（`:168`，`NativeGeneralSettingsPage` 的 `.navigationTitle`） | `tab.barTitle` 表达式：GENERAL=通用设置，其余 tab 为空 | 改成分支常量：GENERAL→`UiStrings.SETTINGS_GENERAL_TITLE`（通用设置），其余→`UiStrings.SETTINGS`（设置，`SettingsPage.swift:59` 是整张 sheet 的 navigationTitle）。**门禁的 `unresolved-title` 因此消失** |
| 五个 tab 的标题策略 | iOS 五个 tab 各自的页自带 `.navigationTitle`（通用设置 :168 / 模型服务 :49 / 内置插件 :60 / 手机权限 :29 / Agent 预设）；`设置`（:59）是 iPad 侧栏的 | 只有通用 tab 有标题，其余四 tab 的 bar 只画了`完成` | 见上：bar 现在至少在四个 tab 上说出这张 sheet 的名字，而不是空白 |

### page-settings-model（`ModelProviderSettingsPage.swift`）

| 控件 | iOS | Android 修前 | 改法 |
|---|---|---|---|
| `服务` 分组头 | `Section { … } header: { Text("服务") }`（`:85-86`）：纯标签，无折叠、无计数 | `⌄ 服务` + 右侧 `1 项`（`SettingsSectionHeader`） | 换成 `SettingsSectionLabel`（纯标签）。折叠控件消失 → 行永远画出来（`PageTokenReferenceTest`/门禁均绿） |
| 选中标记 | `checkmark.circle.fill` + `.tint`（`:129-132`，accent 实心圆 + 白勾） | 无圆勾，只有名称旁的 `默认` 文字 + 右侧键状态 | 新增 `SelectedServiceMark()`：Canvas 画 accent 实心圆 + 白勾，直径取 `settingsLabelStyle().fontSize`（不写裸 dp）；保留 `默认` 徽标 |

### page-settings-network / egress（`NativeShell.swift:444-560`）

| 控件 | iOS | Android 修前 | 改法 |
|---|---|---|---|
| 页面标题 | `网络访问`（`:541`） | `网络访问`（L67 已改） | 复核通过 |
| 每行行尾 `⋯` | **没有**；删除走 `contextMenu`（`:495`） | 每行一个三圆点 | 删掉；整行 `combinedClickable`（长按=contextMenu 语义，点击=同一确认框；确认框才是写） |
| 开关"关"态底色 | iOS 系统灰轨 `#C5C5C7` | Material3 `Switch` 默认 `surfaceVariant` = **#E6E0E9**（8584 px，不属于任何 token） | `SwitchDefaults.colors(...)` 全部 16 个色位改指 token：轨 `colors.borderLight` / 开态 `colors.switchOn`(#34C759) / 拇指 `colors.input` / 禁用 `colors.border` → **#E6E0E9 归零** |
| 行高 35 vs 52.33 | 52.33（List 行余量） | 行本身是 `SettingsFormRow`（`heightIn(min = 52.33)`）；L64 量的 35 是旧实现 | 复核：行高已是 52.33；图上仍比 iOS 高，是因为第二行 `精确主机 …` 还在（见 open questions） |
| 分隔线缩进 | 43 pt | `SettingsFormRow` 的 `dividerLeadingInset` 默认 43 pt | 无 |

### page-settings-plugins（`NativeConfigurationPage.swift`）

| 控件 | iOS | Android | 改法 |
|---|---|---|---|
| `刷新` | 工具栏按钮，**无条件**画（`:76-82`） | 包在 `if (onRefresh != null)` 里；唯一调用方（`PdshNavHost.ConfigurationRoute`）从不传 → 屏幕上永远没有 | 改为无条件画，宿主没命令时 `enabled = false`（**门禁 `conditional-action` 消失**） |

### page-settings-about（`NativeShell.swift:897-908`）

| 控件 | iOS | Android 修前 | 改法 |
|---|---|---|---|
| 卡片数 | **1 张** | 3 张（版本/系统/更多） | 投影只在宿主真读到事实时才发那一段：平台没读→不发"系统"卡；无开发者入口→不发"更多"卡。宿主读不到任何东西时，正好是 iOS 的 1 张 |
| 折叠头 `⌄ … N 项` | 无 | 每卡一个 | 全部删掉，卡片没有表头 |
| 行 | `版本 0.1.0`（`:900`）+ 脚注 `会话记录和文件都保存在这台手机上。`（`:902`） | `版本号` + `构建号`（都是 未知） | 标签改回 `版本`；`构建号` 只在宿主读到构建号时才画；脚注新增 `UiStrings.ABOUT_LOCAL_NOTE` 逐字照抄 |
| 「系统」5 行全 未知 | 无此卡 | 5 行 未知 | 宿主没读 → 卡片不发（不再有 5 个"未知"）；宿主读到 → 显示真值（本次重采里已经是 Android 15 / API 35 / arm64-v8a / sdk_gphone64_arm64 / WebView 131.0.6778.200） |

### page-settings-runtime（`ChatPage.swift:4242`）

| 控件 | iOS | Android | 改法 |
|---|---|---|---|
| 标题 | `运行状态` | `运行状态`（L67 已改） | 复核通过 |
| `读取不到这项状态，未做任何假设` ×6 | 0 次 | 6 次 | **未改**：这 6 行在 `RuntimeDetailsPage.kt`，不在本车道可写面（见 open questions） |

### page-settings-search（`WebSearchSettingsPage.swift`）

| 控件 | iOS | Android | 改法 |
|---|---|---|---|
| 写控件的"能点但什么都不做" | — | 五个写回调默认 `{}`，而 `PdshNavHost` 一个都不传；宿主今天报 `writable=NO` 所以看不出来 | 五个回调改成 `((…) -> Unit)? = null`，控件的 `enabled` = 宿主说可写 **且** 调用方真的给了回调 |

## L74-2 重采数字（Android 对 Android 上一版基线，不是跨平台 diff）

自建 AVD `pdsh-l74-5760`（android-35 / google_apis / arm64-v8a，端口 **5760**，`-no-window`，
`wm size 1206x2622` + `wm density 480`，font_scale 1.0）。**没有 `--write-baseline` / `--update`**：
基线目录原封不动，新采集在 `android/build/screenshots-work/ios-parity/fs-1.0/`。

| 状态 | 改动面 | 差在哪 |
|---|---|---|
| page-settings-about | **18.77 %** | 3 卡 → 1 卡 + 真平台值；折叠头消失；标签 `版本` |
| page-settings-runtime | **5.58 %** | 不是本车道的改动（`RuntimeDetailsPage.kt` 属别人）；本车道没碰这一页 |
| page-settings-model | **2.25 %** | `⌄ 服务 / 1 项` 消失；新增圆勾 |
| page-settings-plugins | **2.23 %** | `刷新` 第一次真的出现在工具栏（禁用态） |
| page-settings-network | **1.10 %** | 行尾 `⋯` 消失；开关换 token 色（#E6E0E9 → token） |
| page-settings-search | **0.39 %** | 写回调改可空后，禁用态的判定没变（宿主 `writable=NO`），差的是别的车道的字号/token 落点 |
| page-settings-default | **0.34 %** | bar 标题表达式换常量，通用 tab 仍是 `通用设置` |

> 这张表只说明"改到了哪些页、动了多少像素"，不是跨平台相似度（理由同 L64 §方法说明）。

## L74-3 其它证据

- `page_structure_check.py`：`ok (1 known divergence, 0 new, 0 stale; 3 whitelisted)` ——
  `mcp-settings` 标题（`MCP 网络与密钥`，`MCPSettingsPage.swift:101`）、`settings` 的
  `unresolved-title`、`native-configuration` 的 `conditional-action 刷新` 三条全部消失。
- `:lib:testDebugUnitTest` 700 tests / 0 failing；`phone-p0-conformance` PASS；
  `phone-android-structure` PASS；`phone-android-tests` PASS（1967 tests, 0 failing）。

## L74-4 改不了的（本车道可写面之外）

| 缺什么 | 为什么 |
|---|---|
| `settings-runtime` 的 6 次重复文案 | 在 `RuntimeDetailsPage.kt`（不在 L74 可写面） |
| `settings-plugins` 的三个玻璃胶囊 + 橙色告警条 + 行图标 + 子行集合 | 页面是 `NativeConfigurationPage.kt`；本车道只被授权改它的 `刷新` 那一条。胶囊本身还缺白色底/圆角/阴影三个 token（见 L67 §5） |
| `settings-model` 的"iOS 是独立 sheet" | 容器由 `PdshNavHost` 的 `SettingsRoute` 决定（本车道禁止改）。补充：iOS 源码里 `模型` 也是 **tab**（`SettingsPage.swift:85`），独立 sheet 只是**截图**是单页；所以真正要改的是采集样本/容器，不是页面 |
| egress 行高仍比 iOS 高 | 第二行 `精确主机 …` 仍在每行渲染；要不要按 iOS 单行显示是交互决策，且 `EgressRuleView` 的投影不在本次改动范围 |
| `onSettingsWrite` 的 `DefaultPermissionTier` | 消费方（新会话权限来源 + 存储）在 `android/app/**`（`HostShell.kt:321`、`HostNavFacts.kt:303`），本车道不可写 |

## L74-5 open questions

1. egress 每行的 `精确主机 任意 http(s) scheme · 任意端口` 要不要只在"规范化形式 ≠ 用户输入"时显示？
   代码注释这么写，但重采图上 15 行全都有这一行。
2. `关于` 页：宿主读到平台事实时是 2 张卡（iOS 1 张）。要么把平台卡移出这一页（没有别的落点），
   要么让 `settings-about` 的契约承认第二张卡。
3. `settings` 的契约标题 `设置`（`SettingsPage.swift:59`）是 iPad 侧栏；iPhone 上每个 tab 页自带标题。
   L74 让 bar 在通用 tab 显示 `通用设置`、其余 tab 显示 `设置`——要不要改成每个 tab 显示它自己的页标题？

---

# L76：两个「谁都不管」的设置子页（`settings-runtime` / `settings-plugins`）

L74 把这两页留在可写面之外，L76 接手。**每一条都指到 iOS 源码的一行**；指不到的写在
「没做」里，不自己发明。iOS 侧坐标一律从 `docs/receipts/ios-baseline-screens/ios-settings-runtime.png`、
`ios-settings-plugins.png` 量（px / 3 = pt），深色取
`docs/receipts/ios-session-audit/screens/current/darkpass-plugins-dark.png`。

## L76-1 逐条对照（`ChatPage.swift` 的 `RuntimeDetailsPage`）

iOS 的 `RuntimeDetailsPage` 在 `ChatPage.swift:4122-4252`，`NativeShell.swift` 只是入口
（`:794 case .settingsRuntime: RuntimeDetailsPage(model: ChatModel.shared)`）。

| iOS（行） | Android 修前 | 改法 |
|---|---|---|
| `状态` 一行，值 = `statusValue`（`:4168-4176`, `:4183-4186`）：`已停止`，或 `运行中 · 已运行2 分钟` | `引擎` 段里两行：`状态` + `已运行` | **合并成一行**：`RuntimeDetailsScreenState.from` 的 `engineRows` 只剩 `runtime.engine.status`，值由 `statusValue(engine, uptime)` 拼（`RUNTIME_STATUS_UPTIME_FORMAT`）。停着的引擎不再显示时长——和基线一样 |
| `本次运行`（`:4189-4195`，条件 `hasCounts`）3 行 | 有，但每行 `未知` 下挂 `读取不到这项状态…` | 保留 3 行；**副标题删掉**（见 L76-3）。`hasCounts` 的行为不变：测量到的全 0 仍然隐藏（`isIdle`） |
| `最近出错`（`:4198-4209`）一句话 | 有 + 重复副标题 | 保留那一句（`读取不到最近一次出错`），**副标题删掉** |
| 动作段（`:4211-4231`）：`停止本地引擎` / `启动本地引擎` | 动作在整页最后 | **移到 `最近出错` 之后**，四个 androidOnly 段之前——基线里它就在这个相对位置 |
| 动作段的 footer（`:4231-4234`） | 只在「停止」分支画 | **两个分支都画**（iOS 的 footer 属于 Section，不属于 stop 分支） |
| `groupHeader`（`:4150-4160`）13 pt 裸标题，**无计数** | 每个组头右侧 `N 项` | 删掉计数（`SettingsSectionHeader` 不再传 `trailing`） |
| 板块顺序：状态 → 本次运行 → 最近出错 → 动作 | 本次运行 → 最近出错 → 引擎 → WebView… | 引擎 → 本次运行 → 最近出错 → 动作 → WebView / 内存 / 电源与散热 / 前台服务 |
| 无 WebView / 内存 / 电源 / 前台服务 | 4 个组 | **保留**：`spec/ui/v1/pages/_android-only-items.json` 注册的平台事实，`page_structure_check` 里 4 条 whitelist 就是它们 |

**契约 vs 代码的数字**：任务书写「Android 8 个折叠段」，代码里是 **7 个**
（`runtime.run / error / engine / webview / memory / power / fgs`）。契约
`runtime-details.json` 有 8 个 section，其中 `section-4211` 是**无标题**的动作段
（按「第一个可点行」判定），所以 8 = 7 个折叠段 + 1 个动作段。L64 数到 8 是把动作段
也算进去了。

## L76-2 token：补了 2 个，不是 3 个

任务书说胶囊缺「白底 / 圆角 / 阴影」三个 token。**量完两张 PNG，只有「底」是真的**：

| 任务书的说法 | 实测 | 结论 |
|---|---|---|
| 白底 | 底是 **`#E9E9EB`**（浅，25096 px）/ **`#39393D`**（深），平涂、**无描边**。它是系统 `secondarySystemFill` 玻璃层合成到当时底色上的结果（浅色 白底 → #E9E9EB，深色 分组卡 #1C1C1E → #39393D，两个都和该规范逐通道相等） | 补 `colors.glassPillFill`，`tier: system`，`provenance.source = system:UIColor.secondarySystemFill`；对比度按 `composite` 豁免 |
| 圆角 | **是胶囊，不是定值圆角**：左缘满足 `x(y) = x0 + r − √(r² − dy²)`，`r = 高度/2`，56.33 pt 的两行胶囊（r 28.17）和 34.33 pt 的单行胶囊（r 17.17）都吻合 | **不补 pt token**：一个固定值会在两种高度里错一个。形状用 `percent = 50`，与 `PageBarCapsule` 同一个比例常量 |
| 阴影 | **没有**：每个胶囊四边都是 `#FFFFFF → #E9E9EB` 一像素抗锯齿直落，没有晕 | **不补**。补一个基线不画的阴影就是把「我觉得应该有」写进 spec |

另外补了第三个（任务书没点名，但橙色告警条必须有）：`colors.systemOrange`
（浅 `#FF8D28` / 深 `#FF9230`，`NativeConfigurationPage.swift:18`
`.foregroundStyle(.orange)`）。主题的 `colors.warning` 是 `#DD8629`，和这个不是一个来源，
所以没有拿它顶。

三个 `ui_check` 规则都过了：`ui_check: ok (5 files, 17 contrast pairs, 7 deferred AA pairs,
1 unmeasured tokens, …)`。

## L76-3 六次重复怎么办的：**收敛成一次**

- 删掉 `RuntimeDetailsPage.kt` 里**全部 16 处** `SETTINGS_UNKNOWN_HINT` 副标题（L64 数到的
  是首屏那 6 处；整页 16 处）。
- 页首改成**一处、指名道姓**：`这台宿主没有报告这些状态：本次运行、最近出错、WebView、内存、电源与散热、前台服务`
  （`RUNTIME_UNMEASURED_GROUPS` + `unmeasuredGroups`，按板块顺序列出含 `未知` 行的那几组），
  下面一行仍是既有规则句 `未测量的值显示为未知，不会当成 0 或默认档位`。
- 保住的两句是**各自成立的不同话**：`读取不到最近一次出错`（`:4200` 那一行的替身，说的是
  「这次读没发生」）、`读取不到引擎状态：先刷新再试，不提供停止或启动`（决定动作能不能给）。
- 重采后页面上 `读取不到这项状态，未做任何假设` = **0 次**（`docs` 里新 sheet 可数）。
- 单测钉住：`the page explains unmeasured values once, with the group names` 断言该句
  只有一个节点、且 `SETTINGS_UNKNOWN_HINT` 一个节点都没有。

## L76-4 `web-search` 死接线：**属实，而且比 L74 说的更深**

`PdshNavHost.WebSearchRoute`（`PdshNavHost.kt:1059-1077`）传了 `state` 和 6 个回调：

| 传的 | 页面收下后 | 事实 |
|---|---|---|
| `onToggle = { SetWebSearchEnabled(enabled) }`（`:1067`） | `WebSearchSettingsPage.kt:303` 的必填 `onToggle: (Boolean) -> Unit` | **函数体里一次都没调用**（全文件只有声明行 + KDoc），死接线 |
| `onSelectBackend = { SelectWebSearchBackend(id) }`（`:1068`） | `:304` 的必填 `onSelectBackend: (String) -> Unit` | 同上，死接线 |
| `onToggleBackends` / `onBack` / `onStartEngine` / `onStopEngine` | `:305` / `:307` / `:314-315` | 真的被调用（`还要知道` 折叠、返回、启停引擎） |
| 五个真写回调 `onModeChange` / `onCommitAddress` / `onCommitKey` / `onClearKey` / `onRemoveConfiguration` | `:308-312` 全是 `null` 默认 | **一个都没传**：`modeWritable`…`removeWritable` 全部为 false，宿主哪怕报 `writable=YES`，五个写控件也永远禁用 |

再往下一层：就算 `onToggle` 被调用，`HostShell.handleHostAction`（`HostShell.kt:521-581`）
**没有** `SetWebSearchEnabled` / `SelectWebSearchBackend` 的分支，会落到
`else -> "宿主未实现：网页搜索开关，本次未提交"`。`HostShell.kt:715-716` 只出现在
`actionLabel()`（给日志/提示取名字）里，不是执行。

结论：**三层都是死的**（调用方传了但页面不调 → 页面调了宿主也不执行）。`PdshNavHost.kt`
是 L69 的地盘，`WebSearchSettingsPage.kt` 是 L74 的地盘，L76 只核实、不改。
最小修法：把那两个参数从签名里删掉（或改成 `null` 默认并删掉传参），再决定五个真写回调
谁来传——**这是 L69 + L74 的联合改动**。

## L76-5 重采数字（Android 对 Android 上一版采集，不是跨平台 diff）

自建 AVD `pdsh-l76-5750`（android-35 / google_apis / arm64-v8a，端口 **5750**，`-no-window`，
`wm size 1206x2622` + `wm density 480`，font_scale 1.0，locale en-US）。**没有
`--write-baseline` / `--update`**：`android/lib/src/test/resources/screenshots/ios-parity/`
原封不动，新采集在 `android/build/screenshots-work/ios-parity/l76/fs-1.0/`，并排图用
`ui-parity-sheet.py --android-dir …` 重铺后只替换了这两张图。

| 状态 | 改动面 | 差在哪 |
|---|---|---|
| page-settings-plugins | **8.80 %**（292671 px / 3162132 px，阈值 8/255） | 三个胶囊 + 橙色告警条 + 🌐 + `刷新` 从工具栏移回页内；样本也补上了 iOS 那条 host 错误 |
| page-settings-runtime | **8.81 %**（278639 px） | 6 处重复文案消失、状态行合并、计数删除、动作段上移、脚注两分支 |

胶囊重采实测：**高 34.5 pt**（iOS 34.33，Δ0.2）、底 `#E9E9EB`、三段 x 16.7–131.0 /
142.7–223.0 / 234.7–349.0（iOS 34.0–127.7 / 143.3–205.3 / 250.0–343.7）。
橙告警条 y **353.3–392.3**（两行）。

## L76-6 没做 / 做不了的（都指到原因）

| 缺什么 | 为什么 |
|---|---|
| 四个 ⓘ 行图标（`子 Agent` / `子 Agent 模型` / `自动执行轮次` / `终端`） | iOS 那四行是 `unavailableRow`（`:110`/`:116`/`:122`/`:128`），只在**分组缺失**时画。Android 的投影只画宿主真给的 group，没有「这个 namespace 缺失」的事实，硬编码四个 namespace 就是发明宿主行为。要做得先让宿主报「期望但缺失」 |
| iOS 是「分组卡 + 6 条分隔线」，Android 是平铺 | 卡片容器属设置族 shell（`SettingsSubPageFrame`，L74 面）；Android 的分隔线已经是 6 条（y 293/345/532/585/728/780 pt），数量对齐、形状不同 |
| `添加插件` 胶囊 iOS 是**禁用**（`.disabled(true)`，`:93`） | Android 故意让它可点，点了打菜单并打印「宿主不支持从手机安装插件」。画成禁用却可点才是骗人；这一条是**有意的差异** |
| `刷新` 的 `isLoading` / `hasDrafts` 禁用条件（`:82`） | Android 的快照里没有 loading / dirty 事实，只能按「宿主给没给重读命令」禁用 |
| 胶囊标签 iOS 被挤成两行、Android 单行 | 宽度不同：iOS 在 34 pt 卡片内缩里有 308 pt，Android 平铺有 370 pt，同样的字不必换行 |
| `engine.uptime` 的白名单说明变旧 | `spec/ui/v1/pages/_whitelist.json` 里 `runtime-details section '引擎'` 的 `androidNeeds` 还写着 `runtime.engine.status`/`runtime.engine.uptime` 两个 row id，合并后只剩前者。**该文件不在 L76 可写面**，留给 owner 改（owner=android-ui, reviewBy=2027-06-30） |

## L76-7 open questions

1. 系统蓝 `#0088FF`（胶囊字/图标、🌐）在 token 表里没有；现在读 `colors.accent`（#3964FE），
   两个胶囊的字色实测差 Δ(57,36,1)/255。要不要立一个 `colors.systemBlue`（和
   `colors.systemOrange` 同一类）？
2. `本次运行` 在「宿主没报计数」时不隐藏（iOS 的 `hasCounts` 隐藏）。L76 把它留在页首那句话里
   点名，但**多了一个 iOS 没有的板块**。要不要改成「没读到就整段不发」？
3. `_whitelist.json` 的 引擎 条目措辞要不要跟着 L76 的合并改？（见 L76-6 最后一行）
4. `settings-plugins` 的样本现在带 `settingsFailure`（为了和 iOS 的 host 未连接状态对齐）。
   采集样本算不算「页面的测试」？如果 L74 认为不算，这条要回退——那橙色告警条在并排图上就看不见了。

---

# L80 车道：page-shell 64.62% + surface-code-block 23.53%（2026-11-02）

验证环境：自建 AVD `pdsh-l80`（android-35 / google_apis / arm64-v8a，端口 **5766**，`-no-window`，
`wm size 1206x2622` + `wm density 480`，font_scale 1.0，en-US）。未触碰 5556 / 5558 / 5670–5765，用完删除。
**没有跑过 `--write-baseline` / `--update`**：`android/lib/src/test/resources/screenshots/ios-parity` 原封不动；
新采集在 `android/build/screenshots-work/ios-parity/fs-1.0/`，并排图用
`ui-parity-sheet.py --android-dir …` 重铺后**只替换了这两张图**。本 lane 的采集样本在
`android/build/screenshots-work/…`，而不是基线目录。

## 1. page-shell：64.62% 的「整块位移」不是位移，是整页底色

先按行扫描再核色，结论是一条 **token 级**原因：

| 层 | iOS `ios-shell.png` | Android `page-shell.png`（改前） | 差 |
|---|---|---|---|
| 分组页底 | **#F2F2F7**（1,709,833 px，占帧 54.1%） | `colors.selector` **#F2F3F5**（1,886,313 px） | (0,1,2)/255 |

`#F2F2F7` 是 `UIColor.systemGroupedBackground`（`PDSHShellPage.swift:21` 的 `List` 保留默认分组底），
`#F2F3F5` 是主题的 selector 填充；两者不是一个来源。任何「任一通道不同即算不同」的统计都会把
54% 的帧整片记成差异 —— 这就是 64.62 里的大头，不是 padding 位移。

复算（1206×2622 原图，iOS 裁 184 px 状态栏带后与 Android 比，阈值 2/255）：

| | 改前 | 改后 |
|---|---|---|
| raw > 0 | 63.17 % | **3.94 %** |
| raw > 2（主口径） | 13.62 % | **3.89 %** |

底色之外，第二次重采才浮出来的真差，按行带修完：

| 项 | iOS | Android 改前 | Android 改后 | 依据 |
|---|---|---|---|---|
| 行距（hairline 到 hairline） | 52.33 pt | 44.67 pt | **52.5 pt** | `44 (pageRowMinHeight) + 8 (codeToolbar)`；三行 + 脚注共 209.5 vs iOS 209.4 |
| 脚注行 | 52.33 pt，文字垂直居中 | 43 pt，12 pt 上下 padding | **52 pt，居中** | 与三行同一节奏（`ios-shell.png` 最后一条 hairline 313.3 → 卡底 365.7） |
| 分组标题 | 墨高 15.6，色 #85858B | 墨高 16.3，色 #66666B | **rowLabel 17 / systemSecondary** | `PDSHShellPage.swift:23`；墨色是 `.secondary` 合成在分组底上 |
| 行标签 / 行值 | #000000 / #8A8A8E | #111114 / #66666B | **systemLabel / systemSecondary** | `LabeledContent` 的 `.primary` / `.secondary` |
| 空态标题 | 20 pt，墨高 19.7 | 20 pt，墨高 19.3 | 同左（`emptyStateTitle` 已在用） | `PDSHShellPage.swift:35` |
| 空态说明 | **15 pt（墨高 14.7）**，两行，行 1 17 个 CJK 字 | 13 sp，一行 | **subheadline 15 / 两行** | `ContentUnavailableView` 的 description；不是 L64 记的 17 pt，也不是 13 pt |
| 空态说明列宽 | 行 1 ink x 87.7–312.3（≈258 pt 列） | 全宽 322 pt | **258 pt**（两侧各 32：16+12+4） | 断在「能用的 / 命令。」同一处 |
| 空态卡内边距 | 顶 34.3 / 底 47 | 上下各 44 | **顶 34 / 底 44** | 卡高 209.5+? ≈ iOS 214.3；图标 y 374.7–418.7 vs iOS 373.7–417.0 |
| 空态图标 | 55.0 × 43.3 | 44 × 44 | **56 × 44** | SF Symbol `terminal` 的实测框 |
| 卡内分隔线 | #E8E8E8 | `colors.border` #E4E4E8 | **`colors.separator` #E8E8E8** | L79 的同源 token（settings 分组线实测） |
| 脚注墨色 | #7F7F7F | #66666B | **`colors.settingsFootnoteInk` #7F7F7F** | L79 的同源 token（`.footnote.secondary` 实得色） |

**为什么不是「整块位移」**：iOS 带 59–62 pt 状态栏，Android 采集隐藏系统栏；这一条是全集已知偏移，
不是本页缺陷。本页真正整片不同的是底色。改后残余 3.89% 主要是两平台字体栅格（同一字符串的墨迹边界
不同）和 3 条 1 px 分隔线，不再有结构块。

## 2. surface-code-block：卡片顶 0 vs 104 是**采样**，不是页面

结论：**采样布局**。`ChatParityScreenshotTest.surfaceCodeBlock()` 只画了
`Column(fillMaxWidth().padding(horizontal=16))`，没有顶部 inset；iOS 的 preview 路由是
`NativeShell.swift:864-868` 的 `ScrollView { DSSCodeBlock(…).padding(.horizontal, 16).padding(.top, 40) }`，
而 `DSSCodeBlock` 自己还有 `.padding(.vertical, 2)`（`Components.swift:224`）：62（状态栏）+ 40 + 2 = **104**。
`CodeBlock` 是可复用组件，没有页边距职责；因此修在**采集样本**，不加 104 pt 到组件。

改后组件本身的三处真差也补齐（`Components.swift:151-225`）：

| 控件 | iOS | Android 改前 | Android 改后 |
|---|---|---|---|
| header 高 | 34 pt | 39.33 pt | **34 pt** |
| header 底 | #F5F6F7 | #E9E9ED | **#F5F6F7**（改正 `colors.codeBanner`，原值在 iOS 全仓 0 px） |
| body 底 | #F9FAFB | #F6F6F8 | **#F9FAFB**（改正 `colors.code`） |
| 换行开关 | 28×28，`text.alignleft` / `arrow.left.and.right` | **无** | **有**（`CODE_WRAP_TAG`，语义 `关闭自动换行` / `自动换行`） |
| 复制反馈 | `复制` → `已复制`，1 s | **无** | **有**（勾 + `已复制`，`copyConfirmHold` 1000 ms） |
| 展开尾部 | 长块（>24 行或 >2400 字）`展开全部 N 行` / `收起`，32 pt | **无** | **有**（`CODE_EXPAND_TAG`） |
| 正文 | mono 14，行距 5（pitch 20.3–21.3） | 12 sp，pitch 14 | **14 mono，pitch 20** |
| 折叠上限 | 300 pt | 无 | `terminalCardMaxHeight` 224（**唯一没对齐的长度**，见 §4） |

主口径（原生 1206×2622，卡片顶已对齐 104，**不扣状态栏**）：

| | 改前 | 改后 |
|---|---|---|
| raw > 0 | 27.31 % | **3.25 %** |
| raw > 2（主口径） | 24.58 % | **3.22 %** |

## 3. 三组口径（同一张并排图）

| 状态 | sheet naive any / >2 | panel raw any / >2（不扣状态栏） | panel raw any / >2（扣 184 px 状态栏，主口径） |
|---|---|---|---|
| page-shell 改前 | 64.47 / 34.80 | 73.27 / 28.61 | 63.17 / **13.62** |
| page-shell 改后 | 34.06 / 33.69 | 27.43 / 27.00 | 3.94 / **3.89** |
| surface-code-block 改前 | 23.49 / 21.50 | 27.22 / 24.61 | 22.43 / 19.09（仅对照） |
| surface-code-block 改后 | 7.95 / 7.49 | 5.09 / **4.49** | 18.00 / 17.99（仅对照，不作主口径） |

说明：

* **sheet naive** 是「左半 vs 右半」直接比，左右两半的 panel 起点相差 39 px（ruler/gap 不对称），
  这个数里含版式本身的错位，不是页面差；改后 page-shell 仍 34.06 主要来自这一条 + 状态栏。
* **panel raw** 是裁掉 ruler/gap 后的两个 panel 原样比，仍含 iOS 状态栏的 62 pt；
  page-shell 的 27.0 主要是这 62 pt。
* **主口径** 按 parent 要求：iOS 裁 184 px 状态栏带，任一分量差 > 2 记 1 px。
  `surface-code-block` 的 sample 已把卡片放到 iOS 的 y=104，所以**不扣**状态栏（扣了反而错位 62 pt）。

## 4. 没对齐 / 达不到的

| 项 | 为什么 / 差多少 |
|---|---|
| 长代码块折叠上限 300 pt | token 表只有 `geometry.terminalCardMaxHeight`=224；新加 300 的 geometry token 会被 `PageGeometryTokenTest` 判孤儿（要求 ≥2 个页面读），spacing schema 上限 64。改用最近的 224，并在注释里标 `unverified geometry`。本 swatch 只有 3 行，不触发折叠 |
| 空态说明第 2 行的 y | Android 490.7 vs iOS 487.0，约 +3 pt；15 pt 行盒与 CoreText 的 leading 不同，已把列宽和断行对齐，vertical 仍差 3 pt |
| 行标签/标题的墨迹边界 | 同一字符串 17 sp CJK 在 Minikin 与 CoreText 的墨高/侧距不同；改后残余的主体就是它，不是结构 |
| 反引号代码块的横向断行 | Android mono 的 advance 比 SF Mono 略宽（`let scheme =` 97.3 vs 94.0 pt），同一宽度的第 2 行少/多 1–2 字符；字号已经对齐 14，继续调只能压字号，会破坏高度 |
| sheet naive 的 39 px 水平错位 | 生成器把 ruler + gap 放在左 panel 前；要消掉得重排 sheet，属 receipt 版式，不在本 lane 改 |

## 5. 门禁

* `:app:assembleDebug` **PASS**。
* `:lib:testDebugUnitTest`：本 lane 的 `CodeBlockSurfaceTest`（4）与 `PDSHShellPageTest`（3）**PASS**；
  整包当前被别的车道未完成的 `ChatRows.kt` token inventory / `WebSearchSettingsPageTest` 拖红（见 §6）。
* `phone-p0-conformance`：本 lane 的 token 与页面检查通过；整包被 L79 刚新增的
  `colors.segmentTrack / separator / settingsFootnoteInk` 缺 provenance 拖红（同一份 `tokens.json`，
  本 lane 只加了 `groupedBackground` + 代码块 spacing + 三条 contrast pair，均已过 `ui_check`）。
* `phone-android-tests` 结果见交付消息。

## 6. open questions

1. L79 的三个新颜色（`segmentTrack` / `separator` / `settingsFootnoteInk`）在本 lane 交付时
   `ui_check` 报缺 provenance；`separator` / `settingsFootnoteInk` 已被 page-shell 复用，
   请 L79 补 provenance + contrast exempt（`separator` decorative、另两个 composite）。
2. `colors.code` / `colors.codeBanner` 的旧值（#F6F6F8 / #E9E9ED）已按
   `NativeParityTokens.swift:35-36` 改正；provenance 从 `:15/:16` 移到 `:17/:18`。
   这是 shared token 的值修正，会影响 ChatPage / ToolRow 的两处取色——按「基线赢」原则应当一起变好，
   但它们不在本 lane 的可写面，需 chat lane 重采确认。
3. 空态说明的 15 pt 与列宽 258 pt 是从 `ios-shell.png` 反推的；如果 iOS owner 能指出
   `ContentUnavailableView` 的 description 实际字体角色，这段可以改成直读 token 而不是推算。

---

# 十二、L78 复测（2026-11-02）：chat 家族 8 张「像素差」的归因与修后

## 12.1 这一节的测法（与本文其余章节不同）

ticket 给的是**逐像素百分比**，不是本文 §1 的「墨迹带 + 字号」测法。为了能对账，这里用同一张
并排图、同一个切法：

* 从 `docs/receipts/ui-parity-sheet/<state>__ios-left.png` 切出生成器自己的两个面板：
  左 x 88..691、右 x 709..1312、y 114..1425（各 603×1311，0.500×）；
* 任一 RGB 通道差 > 2 记一个不同像素；百分比 = 不同像素 / 603×1311；
* 另给一列 1206×2622 原图的同法数字，避免 0.5× 重采样把边缘抹宽。

**这个数字不是跨平台视觉一致性的证明**（README 已写明）：iOS 状态栏、iOS composer 的投影、
CoreText vs Minikin 的字形栅格都会贡献它。它只回答一个问题：**ticket 表上的数字现在是多少、
剩下的差在哪**。

## 12.2 修前 → 修后

| state | ticket 修前 | 本 lane 复测修前（sheet） | 修后（sheet） | 修后（原图） |
|---|---:|---:|---:|---:|
| page-chat-permission | 50.02 % | 57.61 % | **10.57 %** | **8.30 %** |
| page-chat-assistant | 29.94 % | 29.30 % | **15.98 %** | **13.78 %** |
| page-chat-failed | 24.66 % | 23.08 % | **14.62 %** | **12.96 %** |
| page-chat-queued | 20.29 % | 19.43 % | **16.13 %** | **15.46 %** |
| page-chat-draft | 43.14 % | 36.38 % | **26.57 %** | **22.77 %** |
| page-chat-official | 27.58 % | 27.38 % | 26.52 % | 25.14 % |
| page-chat-long | 45.05 % | 37.62 % | 37.37 % | 34.19 % |
| page-chat-default | 34.05 % | 37.50 % | 37.82 % | 36.07 % |

ticket 的修前与本地复测的修前在 permission/long/draft 上差 6–10 点（切法/容差不同：同一张
permission 并排图，ticket 记 50.02 %，本节切面板记 57.61 %）；**修后一列全部是本节测法**。
8 张没有一张到 5 %，卡点见 §12.5。

## 12.3 每张的差异带与归因（修前）

坐标都是 frame px（pt = px/3），在 1206×2622 原图上量。

| state | 修前差异带（y 范围 / 占该带） | 归因 |
|---|---|---|
| permission | 0–2622 整帧 57.6 %；整卡填充（两张卡合计约 40 % 帧） | **不是同一主体**：iOS 是 `-uiPreview chat.permission` 的两张卡独立屏（无页头/无 composer，卡在安全区居中），Android 是整页。**外加一个 token 错值**：卡底 iOS `#F5F6F7`、Android `#F2F3F5`，绿通道差 3/255 → 整卡面积被判不同 |
| assistant | 1487–1887（89 %）、945–1065（31 %）、2146–2216 / 2492–2581（69 %/64 %） | **整块位移 62 pt**（Android 页被画在 874 pt 全帧，iOS 页在 62 pt 安全区内）+ 正文左边距 16 vs 32 + composer 下方 42 pt 多出来 + iOS composer 投影 |
| failed | 1359–1868（62 %）、2383–2603（40 %） | **采错样本**：capture 用的是 gate 的 `chatStateWithTopError()`（顶部橙横幅 + 另一段对话），iOS 是两条气泡 + 最后一条下的红字 |
| queued | 2076–2216（90 %）、1571–1729（45 %） | 队列条缺失（`ComposerState.queued` 没填）+ 气泡底灰 vs 蓝 + 行位置 |
| draft | 954–1130（CTA 边 83 %）、1619–1840（38 %）、2493–2577（67 %） | 空态**顶对齐**（标题 y 137 vs iOS 261.7）→ 应贴 composer；CTA 48 vs 50；composer 投影；草稿文本行盒 17/20.4 vs 16/24 |
| official | 335–565（84 %）、1130–1310（78 %） | **内容不同**：iOS 富 transcript 6 块，Android 2 行；见 §12.4 |
| long | 1658–1879（72 %）、204–387（68 %） | **滚动位置**：iOS 是 5000 字消息 + 12 行回答滚到尾部（画面里只剩 composer 和「回到最新」），harness 没有滚动位置，样本是 6 轮 |
| default | 360–927（92 %） | **内容不同**：iOS 是真实宿主的 transcript（逐次运行还会变，`INDEX.md` 写明），Android 是 gate 的固定样本 |

## 12.4 `chat-official` 的 6 块：样本不同，还是真缺？

**两者都有，且要分开说：**

1. **样本不同（可修而本轮没改）**：iOS 的 `chat.official` 是 `PreviewChatItems.official`
   （`NativeShell.swift:953-1040`）：一条用户消息、一条 context、一条 reasoning、一个 bash
   工具、6 次 edit、一篇长 markdown，再加 `NativeTranscriptProjector.changes(forTurn:)` 生成的
   「已编辑 6 个文件」卡。Android 的 `ChatParitySamples.chatOfficial()` 是「hello test 123 +
   一段回答 + 统计行」——**不是同一个会话**。
2. **真缺（不是采样能补的）**：即使把样本换成上面的会话，Android 也画不出 6 块里的 5 块：
   * `ChatRows.splitFences` 只认三反引号代码块（`ChatRows.kt:332`），没有 markdown 表格、
     `$$…$$` TeX、字面 HTML、`[^note]` 脚注的渲染器；
   * `:lib` 里没有 `已编辑 6 个文件` 卡（`grep 已编辑/changedFiles` 为 0；iOS 是
     `NativeChangedFilesCard.swift:5`）。
   能画的只有代码块（Android 有 `CodeBlock` + 语法着色）。

结论：**「6 块」的差异里，第一条用户消息/整段 thread 是采样差，表格/公式/HTML/脚注/文件卡是
真功能缺口**。本轮**没有**改样本去凑这个数字（那会把 25 % 洗成好看但无意义的数），也没有为了
像素去伪造一块 UI。

## 12.5 到不了 5 % 的四个硬卡点（用测量说话）

1. **iOS 状态栏带**：每张图 0–62 pt 的 iOS chrome 墨迹 45,871 px = 帧的 **1.45 %**；
   Android capture 不画系统栏（capture 条件），这 1.45 % 永远不会归零。
2. **iOS composer 投影**：`ChatPage.swift:1897-1898` 的两层 `.shadow(3 %, radius 16/24)`，
   Android composer 是描边无投影。实测 composer 上下两带 69,494 + 59,443 px = **4.1 %** 帧
   （assistant）。
3. **字形栅格**：同一个字串、同一字号/位置/颜色（permission 的「允许一次」，17 pt semibold
   白字压同一个 `#3964FE`），两个平台的墨迹仍有 **49.1 % 的墨迹像素**不同（该按钮区域
   1.93 %）；换行点也会因此不同（failed 第二条气泡：iOS 3 行 257.7 pt、Android 2 行 277 pt，
   Roboto 比 SF Pro Text 窄）。
4. **样本/滚动**：official（富文本缺口）、long（无滚动位置）、default（真实宿主 transcript
   逐次变化）。这三张的基线内容本身就不可复现。

把 1+2+3 相加，一个「布局完全正确」的带 composer 的 chat 页也还有 **约 6–7 %**；
permission 没有 composer 投影，地板约 5 %，但它还叠着卡内文字排版（iOS 副标题 semibold、
命令详情 mono、`✋` 图标）的差。5 % 在整帧逐像素法下低于平台地板。

## 12.6 本轮改了什么（可写清单内）

| 文件 | 改动 | 依据 |
|---|---|---|
| `ui/page/ChatRows.kt` | 行左右内边距 16 → 32（`UiMetrics.CONTENT_COLUMN_INSET_PT`）；删掉 assistant 行下那条 iOS 不画的 28 pt 动作行 | `NativeParityTokens.transcriptSide = 32`（`ChatPage.swift:1172`）；iOS 只在 user 行画 `NativeMessageActions`，assistant 用 contextMenu |
| `ui/page/ChatPage.kt` | 页头 44 → 50 + 0.5 pt 下边线；空态引擎卡改为贴 composer（bottom 对齐 + 48 pt 底距）；dock 行距 40 → `UiMetrics.flowGap`(6) | `headerHeight=50`、`ChatPage.swift:196-204`；`ios-chat-draft.png` 标题 y 261.3；`ChatPage.swift:1795` |
| `ui/surface/Bubble.kt` | 气泡底 `colors.selector` → 新增 `colors.userBubble` `#EDF3FE` | `NativeChatTheme.bubble = NativeParityTokens.userBubble`；PNG 实测 `#EDF3FE` |
| `ui/surface/ApprovalCard.kt` | 卡底 → 新增 `colors.approvalCard` `#F5F6F7` | `NativeChatTheme.selector`；`ios-chat-permission.png` 实测 `#F5F6F7` |
| `spec/ui/v1/tokens.json` | 新增 `colors.userBubble`、`colors.approvalCard`、2 条 provenance、3 条 contrast pair；两行 README §4 表同步（checker 强制集合相等） | 同上 |
| `androidTest/.../ChatParityFrame.kt` | chat parity capture 加 62 pt 上 / 42 pt 下安全区，页面与 iOS 面板同一个内容盒 | 实测：iOS 页头 62..112、composer 底 2495 px = 831.7；与 settings lane 的 `parityFrame` 同一做法 |
| `androidTest/.../ParityScreenshotTest.kt` | `page-chat-failed` → `ChatParitySamples.chatFailed()`（红字行，不是横幅）；`page-chat-draft` → `chatDraft()`；`page-chat-default/long` 保持注册样本并注明不可比 | 注册表本身的 note 已写明这四张的样本差 |
| `androidTest/.../ChatParitySamples.kt` | 文案改成 iOS 源码的 ASCII 标点/去掉 markdown 反引号；`chatDraft/chatLong` 的 send key 改回禁用态；`chatQueued` 填 `ComposerState.queued`；`chatLong` 补 5000 字 user 行 | `NativeShell.swift` 的 `PreviewChatItems`；`ios-chat-*-png` 实测 |
| `androidTest/.../ChatParityScreenshotTest.kt` | `page-chat-permission` 改拍「两张卡」本身（iOS 基线就是这张 swatch，无页头/无 composer），并留注释 | `NativeShell.swift:848-861` |

## 12.7 门禁

* `:lib:testDebugUnitTest :app:assembleDebug` **PASS**（lib 711 tests；app 打包成功）。
* `phone-android-tests` **PASS**：1986 tests, 0 failing。
* `phone-p0-conformance` **FAIL**：唯一一条新 divergence 是 `settings`（`0/0 0/0 0 1 0 <- new`，
  `SettingsPage.kt` 的 `if (tab == SettingsTab.GENERAL) …` 动态标题，属 L79 的 in-flight 改动）；
  `chat` 行是 `0/0 0/0 0 0 0`。本 lane 的 `ui_check`（含新增 token/contrast/README）通过。

---

# L79（2026-11-02）：settings-about 79% / settings-default 53% —— 两个整块因，不是控件

本 lane 只碰 `settings-about` 与 `settings-default`（`NativeConfigurationPage.kt` 属 L76，
`settings-plugins` 只量不改）。两张并排图已重出（Android 侧来源
`android/build/screenshots-work/ios-parity/fs-1.0`，L79 采集；`metrics.txt` 是全仓 27 行的
索引，本 lane 不动它，所以它的 `# android src` 仍写 L75 合并目录）。

## L79-0 先说度量：79.17% / 52.96% 这个数**不可能**到 5%

需求方的量法是「把 sheet 从中间切成左右两半，逐像素比」。这张 sheet 的几何是
`22 + 56 + 10 + 603 [iOS] + 18 + 603 [Android] + 22 = 1334`，从 667 切下去时

* iOS 面板从第 88 列开始，Android 面板从第 709 列开始 → 两半相比等于把 Android 面板
  **整体左移 42 px（14 pt）** 再比；
* 左半还多出 88 列白边，右半多出 22 列白边。

所以**两张面板完全相同**时这个度量也不是 0：本 sheet 实测 **14.18%（about）/ 20.68%（default）**。
79.17 / 52.96 里有一大半是这张合成图的切法，不是页面。下面所有「改前/改后」同时给两个数：

* **对齐口径**：按面板真实边界（x 88..690 / 709..1311，y 114..1424）对齐后逐像素
  `>0`，这是页面本身的差；
* **需求方口径**：原样的左右半切法，它的地板见上。

## L79-1 归因：两个整块因

### page-settings-about（79.17%）

逐行扫：**第 0 行就不同，一直 different 到卡片底**——这就是「整屏底色不同」的特征。
把像素按类拆开（全帧 3,162,132 px）：

| 类 | 占全帧 | 说明 |
|---|---|---|
| iOS 页底 ↔ Android 页底 | **52.7%** | `#F2F2F7`（iOS `systemGroupedBackground`）vs `#F2F3F5`（`colors.selector`），三通道差 (0,1,2)。**整屏一档灰**，逐像素 >0 的统计把它全记成不同 |
| iOS 页底 ↔ Android 白 | **33.5%** | Android 多出**第二张卡**（系统：Android / API 35 / ABI / 设备 / WebView，262 pt 高） |
| iOS 白 ↔ Android 页底 | 2.1% | 第一张卡位置差 10 pt（子页 list top inset 34.67 vs iOS 45.0），且多一行「构建号」 |
| 两边都是白 | 7.9% | 第一张卡重叠的部分，本来就对 |

结论：**没有一条是「某个控件差」**。两个整块因 = 页面底色 token 选错 + 一张 iOS 没有的卡。

### page-settings-default（52.96%）

同一拆法：

| 类 | 占全帧 | 说明 |
|---|---|---|
| iOS 白 ↔ Android 页底 | 22.5% | |
| iOS 页底 ↔ Android 白 | 14.3% | 两者合计 **36.8% = 整块竖向位移 61.3 pt** |
| 两边都是页底 | 6.5% | 底色 token 差（同上） |
| 两边都是白 | 43.6% | 已对齐的卡面 |

位移是**逐卡精确 61.3 pt**，不是累积误差：Android 卡顶 140.7 / 280.3 / 524.7 / 769.0 pt，
iOS 202.0 / 341.7 / 586.0 / 830.3 pt，四张卡的**高度两边完全一致**（104.7 / 209.3 / 209.3 / 43.7）。
原因是帧条件而不是页面：iOS 基线是设备截图，带 62 pt 状态栏；Compose harness 隐藏系统栏，
所以页面里的 `statusBarsPadding()` 归零，整页比基线高一个安全区。
**改一个 padding 归零修不好它**——要补的是帧，不是页面。

## L79-2 改了什么

| 文件 | 改动 | 依据 |
|---|---|---|
| `spec/ui/v1/tokens.json` | 新增 `colors.segmentTrack` `#EEEEEF`、`colors.settingsFootnoteInk` `#7F7F7F`、`colors.separator` `#E8E8E8`（各带 provenance）；复用 L80 的 `colors.groupedBackground` `#F2F2F7` | 三张 PNG 实测：轨道 71,563 px `#EEEEEF`；脚注 `#7F7F7F`（值却是 `#8A8A8E`）；每条分隔线 3 px 全 `#E8E8E8` |
| `ui/theme/UiTokens.kt` | 追加 3 个颜色字段（`segmentTrack` / `settingsFootnoteInk` / `separator`），**只追加** | token codegen 的装配，和 L75/L78/L80 的 token 同一做法 |
| `ui/SettingsMetrics.kt` | 新增 `SUB_PAGE_GROUPED_TOP_INSET_PT=45`、`PARITY_SAFE_AREA_TOP_PT=62`、`ROW_TEXT_OPTICAL_OFFSET_PT=-1`、`MENU_TRAILING_INSET_PT=17.6`、`MENU_CHEVRON_SLOT_PT=16`；`SEGMENTED_PADDING_V_PT` 10 → **9.33** | 实测：about 卡顶 151.0 = 62+44+45；iOS 语言行 value 右缘 351.7 / 上下箭头右缘 367.7；轨道下沿 158 → list 167.3 |
| `ui/surface/SettingsChrome.kt` | grouped 底 → `groupedBackground`；轨道 → `segmentTrack`；分隔线 → `separator`；行 label/value/脚注走 `LocalSettingsRowInk`（页面可注入 iOS 系统三色）；行文字 1 pt 光学上移；段选标签 13 pt、全部 `.label` 色；脚注在 52.33 pt 行内**垂直居中**（opt-in）；菜单行改用 17.6/16 的尾部几何；导航标题 `.label` `#000000` | 逐条都在上表；脚注居中前实测偏上 10.4 pt，菜单行 value 偏左 20 pt |
| `ui/page/SettingsPage.kt` | 白底顶栏（bar + picker 条 0..167.3）+ 列表区 `groupedBackground`；bar/picker/通用 tab 注入系统墨色；value 统一 `systemSecondary`（含「未设置」）；菜单行尾部几何 | `ios-settings.png` 0..167 pt 全白（`#FFFFFF`）、167.3 起才 `#F2F2F7` |
| `ui/page/AboutPage.kt` | **删掉平台卡与「构建号」行**；子页 list top inset 45.0；继承 grouped 底与系统墨色 | `settings-about.json` 写明「one version row + one sentence; no group header」，`NativeShell.swift:897-908` 就是两行；L74-5 的 open question #2 以「页面按 spec」收口 |
| `androidTest/.../ParityScreenshotTest.kt` | 两个 settings 状态套 `parityFrame`：顶部补 62 pt iOS 安全区（band 颜色 = 页面自身的顶部色：default 白 / about 分组灰） | 帧条件，不是页面 inset；页面里的 `statusBarsPadding()` 在真机可见系统栏时本来就会给这一条（L78 的 chat 帧同做法） |
| `androidTest/.../SettingsParitySamples.kt` | `aboutState()` 不再塞平台事实 | 同 AboutPage |
| `ui/page/AboutPageTest.kt` | 断言改为「一张卡、一行、一句」；平台/构建号行断言不存在 | 同 AboutPage |

## L79-3 改前 / 改后

| 状态 | 对齐口径 改前 | 改后 | 需求方口径 改前 | 改后 | 该口径地板 |
|---|---|---|---|---|---|
| page-settings-about | 92.53% | **2.23%** | 79.18% | **16.23%** | 14.18% |
| page-settings-default | 59.30% | **8.29%** | 52.86% | **22.76%** | 20.68% |

改后几何是**逐像素级对齐**：四张卡顶 202.0 / 341.7 / 586.0 / 830.3（iOS 同值），about 卡
151.0..255.7（iOS 同值）；`>2/255` 口径下 default 是 6.52%。

剩余差异（default 的 8.29% 拆开）：

| 带 | 占全帧 | 内容 |
|---|---|---|
| 0..62 pt 状态条 | **1.99%** | iOS 的时钟/信号/电池 + 灵动岛（黑色 1.4%）。Android harness 隐藏系统栏，这条带是空的——不可仿造 |
| 62..106 pt 导航条 | 1.52% | **完成 的玻璃胶囊**（iOS 26 的 toolbar glass，x 302.7..389.7 × y 60..104.7，`#FDFDFD` 渐变 + 阴影）占其中 1.2%；Android 只有蓝字 `完成`。token 层没有玻璃材质，**没改** |
| 106..168 pt 选择器条 | 1.34% | 主要是同一块玻璃向下溢出的 1-2/255 底色（>0 才算差），轨道与五个标签本身已对齐（标签墨盒 x 差 ≤0.3 pt、y 差 ≤0.7 pt、13 pt 同字号） |
| 四张卡 202..874 pt | 3.44% | 字形栅格（CoreText vs Minikin：同一 17 pt CJK，iOS 墨高 15.0、Android 15.67-16.0，行位置已用 -1 pt 光学补偿对到 ±0.3 pt），卡圆角（iOS continuous vs Compose 圆弧）1 px 抗锯齿边，开关 4,134 px |

about 的 2.23% 里状态条占 1.45%、卡 0.71%（字 + 圆角边）、标题行 0.07%。

## L79-4 settings-plugins：只量不改

现有 sheet（`page-settings-plugins__ios-left.png`，L75 合并采集）实测：

* 对齐口径 **22.42%**（`>0`）；需求方口径 **19.94%**（与需求方的 19.77% 同一量法）。
* 差异分布：行区（300..620 pt）10.6%、底部（620..874 pt）21.7%、告警条（220..300 pt）
  10.2%、三个胶囊（150..220 pt）5.5%。都在 L76 的 `NativeConfigurationPage.kt` 面上。
* 本 lane 对共享 chrome 的改动（段选标签 13 pt/系统墨色、轨道 `#EEEEEF`、分隔线 `#E8E8E8`、
  菜单行尾部几何）会改变这张 sheet 的像素，但**没有重采**它——L76 收口时按自己的数字重出。

## L79-5 没做到的

1. **`< 5%` 在需求方口径上不可达**：同样的两张面板也有 14.18 / 20.68 的地板（L79-0）。
   在能测页面本身的对齐口径上，about 已 2.23%，default 8.29%，卡在下面三条：
2. **完成 的玻璃胶囊**（default 1.2%，且向下溢进选择器条）：iOS 26 toolbar glass 是模糊材质，
   本仓没有对应 token；用一个纯色胶囊假做只会把 1.2% 换成另一种形状差，所以留白并登记。
3. **状态条/灵动岛**（2.3% / 1.45%）：任何跨平台像素比都会吃到，除非伪造系统栏。
4. **字形栅格**（default 3.1% 的卡区里的大头）：同一 17 pt CJK 在两套栅格上墨高差 0.67-1.0 pt；
   已用 −1 pt 光学位移把行中心对到 ±0.3 pt，剩余是笔画形状本身。
5. **文案一处**：繁忙时的发送行为 的值 iOS 是 `排队发送`、Android 是 `排到下一轮`
   （`UiStrings.BUSY_ENTER_QUEUE`，本 lane 的 UiStrings 只许新增，没改）。约 0.13%。

## L79-6 open questions

1. `parityFrame` 的 62 pt 放在 harness（`ParityScreenshotTest`）而不是页面：页面已有
   `statusBarsPadding()`，真机可见系统栏时会自己拿到这一条；放在页面会双计。这是帧条件，
   建议后续统一成一个所有 parity 状态共用的 frame（L78 的 chat 已经复制了同一做法）。
2. 共享 chrome 的改动会波及 model / network / runtime / search / plugins 五张 sheet 的像素
   （墨色、段选标签、轨道色、分隔线色）：它们各自的 owner 重采时会看到这几十像素的位移，
   不是回归。要不要在 `SettingsChrome` 里做成按页面 opt-in（本 lane 的墨色已是 opt-in）。
3. `UiTokens.kt` 本 lane 只追加了 3 个字段；L78/L80 同文件并发追加，建议 token 装配也按
   家族拆文件，避免多 lane 同点写。
4. `page_structure_check.py` 用大括号切函数：一个 `= expr` 体函数会让它把后续声明吞进
   span，`完成` 的 `text = label` 就被读成 unresolved-action（本次真实踩到）。已改成块体
   规避，但 checker 本身值得修。

---

# 十三、L84（2026-11-02）：chat 的真缺渲染器（表格 / 数学 / 字面 HTML / 脚注 / 已编辑卡）

这一节只碰 `page-chat-official`。**样本是我（L84）搬的，不是 L78 搬的**：L78 的 §12.4 明确写了
「本轮没有改样本」，`ChatParitySamples.chatOfficial()` 在本 lane 开工时仍是「hello test 123 +
一段回答 + 统计」。为让渲染器真的被采到，本 lane 按 `NativeShell.swift:953-1040`
（`PreviewChatItems.official`）逐字转写：用户消息、context 块、reasoning 行、bash、6 次 edit、
长 Markdown、由 6 次 edit 派生的「已编辑 6 个文件」卡。**这不是为了凑数字改样本**——改的是
「两侧内容不同」，不是把 Android 样本裁成 iOS 截图的样子。

## 13.1 iOS 的五个渲染器各自做了什么（逐项行号）

| 项 | 解析 | 绘制 | 结论 |
|---|---|---|---|
| 表格 | `NativeMarkdownModel.swift:164-178`：GFM `Table` → `.table(header, rows, alignments)` | `NativeMarkdownBody.swift:103-105` 分派 → `NativeMarkdownTable:132-199`：`ViewThatFits` 网格（`:151-162`）/ 逐行卡片（`:164-192`）二选一；行 `:201-242`，表头 semibold + `NativeChatTheme.selector` 底（`:224`），每格底部 0.5 线（`:221`），格内 16h/10v（`:219-220`），GFM 对齐在 `:227-241` | **真表格**，不是等宽文本。手机宽度下 `ViewThatFits` 走网格分支 |
| 数学 `$$…$$` | `NativeMarkdownModel.swift:101-106`：`$$…$$`/`\[…\]` → ```` ```math ```` 块；`:108-118`：`\(…\)`/`$…$` → 代码 span 占位；`:205-208` 再变 `.math` | **真排版**：display 用 `NativeMathView`（SwiftMath `MTMathUILabel`，`NativeMarkdownBody.swift:324-344`）横滚（`:108-111`）；行内用 `MathImage` 出图（`:285-290`），失败才回退成原样 TeX | 不是原样显示；`ios-chat-official.png` 里 `E = mc²` 是排出来的 |
| 字面 HTML | `HTMLBlock` → `.paragraph([.html(rawHTML)])`（`NativeMarkdownModel.swift:179`）；`InlineHTML` → `.html`（`:215`） | `case .html(let value): return Text(value)`（`NativeMarkdownBody.swift:293`） | **原样当文本**：不解析、不转义、无 WebView。Android 保留 `<b>…</b>` 字样就是照做 |
| 脚注 `[^note]` | `:85-99` 抽走 `[^id]:` 定义行、把 `[^id]` 换成标记；`:221-235` 变 `.footnote`；`:51-59` 在正文后追加「**脚注**」段 + 每个定义一段 | 引用画成 9 pt、上移 6 pt 的上标（`NativeMarkdownBody.swift:291-292`） | 有引用上标 + 脚注节。**定义正文被丢**：`:56` 把定义的块子节点喂给 inline 解析器，什么都不产出；基线里就只剩 `[note]`，Android 按这个输出照做 |
| 已编辑卡 | `NativeTranscriptProjector.swift:155-193`：按 turn 扫 `toolCall`、状态 `.ok`、工具 ∈ {write, edit, str_replace_editor}，从 **arguments** 取 path/old/new，LCS 在 `:240-254`；模型 `NativeConversationModels.swift:226-242` | `NativeChangedFilesCard.swift:5-100`：60 pt 表头（`:44-46`）+ 40×40 图标（`:19-29`）+ 标题（单文件用文件名，多文件「已编辑 N 个文件」，`:31-32`）+ `+N -M`（`:36-41`）；≤4 行（`:12`、`:51-74`）；>4 时「全部 N 个文件 ⌄」/「收起」（`:75-90`）；`colors.input` 底 + 0.5 描边 + 12 圆角（`:93-97`）；位置 `ChatPage.swift:3699-3701` | 真卡，不是一行字 |

## 13.2 Android 补了什么、没补什么

补（`ui/surface/MarkdownModel.kt` / `MarkdownBody.kt` / `ChangedFilesCard.kt`，`ChatRows.kt` 接上）：

* **块间距 20 pt、正文 24 pt 行距**：`NativeMarkdownBody.swift:27/33`；旧的 `splitFences` 只有
  5 pt 间距、行距按字体默认（约 20.3），这是长回答页尾部整体位移的主因之一。
* **表格**：表头 `colors.approvalCard`（= iOS `NativeChatTheme.selector` `#F5F6F7`）底、每格底部
  0.5 线、GFM 左/中/右对齐、等分列宽。
* **数学**：一个有界 TeX 子集（变量斜体、`^`/`_` 上下标、常见符号表），display 横滚；**未知命令
  原样保留**（不吞内容）。不是 TeX 引擎，也不假装是。
* **字面 HTML**：文本原样，`<b>` 不上屏为粗体——与 iOS `Text(value)` 一致。
* **脚注**：行内小号上标 + 文末「脚注」节（含 iOS 现状的定义正文丢失）。
* **内联**：`**粗体**`、`*斜体*`、`~~删除线~~`、`` `code` ``、链接下划线。
* **已编辑卡**：数据来自 `ChatScreenState.from` 对 tool-call `arguments` 的扫描（新增
  `ChatRow.Assistant.changes`，默认空），`lineDelta` 逐字移植 iOS 的 LCS（`+N -M` 同值，
  单测 `ChangedFilesCardTest` / `ChangedFilesProjectionTest` 锁定），折叠 4 行 + 「全部 N 个文件 ⌄」。
* **首帧滚到尾**：`ChatPage.kt` 的 `LaunchedEffect` 原来在首帧拿不到 `totalItemsCount`，带历史的
  会话会停在顶部；iOS 是 `scrollTo(tail, anchor: .bottom)`（`ChatPage.swift:1278`），改成等首帧
  布局后 `scrollToItem(last, Int.MAX_VALUE)`。

没补（都写清原因）：

1. **表格的「逐行卡片」回退**（`NativeMarkdownBody.swift:164-192`）：Compose `Row` 没有
   `ViewThatFits`；402 pt 基线永远走网格分支，回退分支没有可比较的对象，先不写。
2. **MathImage/SwiftMath 等价排版**：自写子集能排出 `E = mc²`、`x²+y²=z²`，但不是 TeX 引擎；
   分式/根号/矩阵等按原始 TeX 文本显示（iOS 会排出来）。
3. **图片**（`case .image`）：iOS 会拉 `AsyncImage`/本地图；Android 仍按文本显示。
4. **链接跳转**：只有颜色 + 下划线，没有 `openURL` 路由。
5. **列表 checkbox 图标**：iOS 用 `checkmark.square.fill`/`square`，Android 用 `[x]`/`[ ]` 文本。
6. **heading 的 24/22 pt**：tokens.json 没有这两个角色，用 20 pt `emptyStateTitle`。

## 13.3 复测数字

同一张并排图、两种量法（L78 §12.1 的切法 + 原图逐像素，任一通道差 >2 记不同）：

| 口径 | 修前 | 修后 |
|---|---:|---:|
| sheet 面板切法（603×1311） | 26.52 % | **21.86 %** |
| 原图 1206×2622 | 25.14 % | **19.41 %** |

## 13.4 剩下的 19.41 % 在哪里（量出来的，不是猜的）

把 Android 原图相对 iOS 逐行平移、找全局最优位移：**-50 px（16.7 pt）时 330..1990 这段的差从
17.4 % 降到 8.59 %**。也就是说这一张剩下的差**主要是一段整体上移，不是某一块没画**。拆开：

| 差异 | 量值 | 归属 |
|---|---:|---|
| 卡底 → composer 顶 | iOS 184 px / Android 217 px（**+33 px ≈ 11 pt**） | 页面几何（transcript 底距 + composer 顶距），不在本 lane 的渲染器里 |
| composer 卡顶 | iOS 2154 / Android 2136（Android 高 18 px = 6 pt） | 同上，L78 的 chat 家族共用几何 |
| 尾部内部（代码块底 → 卡顶） | iOS 565 px / Android 615 px（**+50 px**） | Compose 文本盒 vs SwiftUI：两行段落 48 pt vs 44.3 pt；display 数学块 Android 61 px vs iOS 的 SwiftMath 图高约 44 px（图片没有行盒）。试过 `LineHeightStyle` trim，实测把 19.41 推到 19.71，已回退 |
| 状态栏带 0–62 pt | 1.45 % 帧 | iOS 系统 chrome，capture 条件（L78 §12.5） |
| composer 与统计行字形/投影 | 2100–2500 带 20–63 % | L78 §12.5 的地板 |
| 字形栅格 | 全帧 | CoreText vs Minikin |

卡本身不是差异源：卡高 iOS 841 px / Android 842 px，行高 44 pt、表头 60 pt、`+6 -6`、
`全部 6 个文件` 都对上了；它整体跟着尾部上移 50 px，所以整块被记成不同。

## 13.5 越界（单独列，别埋）

1. **`ui/state/ChatScreenState.kt`**：可写清单里没有它。为了让卡有数据（`ToolEntry.filePath` 在
   生产路径永远是 null，全仓只有测试赋值），按 L84 与协调方的约定只做三处增量：
   `ChatRow.Assistant.changes`（默认空）、`from()` 收尾按 turn 扫 `arguments`、卡片模型放
   `ui/surface/`。没有改 `RunBuilder.add` 的既有语义，没有改别的 row 类型。
2. **`ChatParitySamples.chatOfficial()` 的样本**：见本节开头——是 L84 按 iOS 源码转写的，
   不是 L78 换的。测试只加了内容，没有动别的状态。
3. `ChatPage.kt` 的首帧滚尾修正（见 13.2）会改变其他 chat 状态的 capture 像素（它们都是短内容，
   `Arrangement.Bottom` 之下不受影响；但 assistant 的正文行距/块距从 5 pt/20.3 变成 20 pt/24，
   那张 `page-chat-assistant.png` 已过期）。本 lane 只重采了 `page-chat-official`。

## 13.6 门禁

* `:lib:testDebugUnitTest :app:assembleDebug` **PASS**。
* `phone-android-tests` **PASS**：2027 tests / 0 failing（`:lib` 752）。
* `phone-p0-conformance` **PASS**（`ui_check` 含 token/provenance/contrast、page-structure 1 known / 0 new）。

## 13.7 open questions

1. **那 17 pt 的尾部上移是页面几何，不是渲染器**：`transcript` 的底距与 composer 顶距如果按
   `ios-chat-official.png` 收一次，这一张还有约 8 个点可拿（dy=-50 时该带 8.59 %）。归属是 chat
   页几何（L78 的家族），本 lane 没动。
2. **iOS 自己丢了脚注定义正文**（`NativeMarkdownModel.swift:56` 把块节点当 inline 解析）。Android
   照做才和基线一致；如果 iOS 修，`MarkdownParser.parse` 的脚注节要一起改。
3. `ToolEntry.filePath` 的投影缺口仍在：卡片自己走 arguments，但工具行的「打开文件」chip 在生产
   路径仍永远不显示。
4. 卡片的 40×40 图标是文本字形（▤），iOS 是文件类型图标集；表格的逐行卡片回退、图片、链接路由
   按 13.2 的清单后补。
