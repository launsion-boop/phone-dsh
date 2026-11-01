# 01 — 当前 iOS 预览层审计（只读）

- 审计对象：`examples/probe-app/PhoneDSHProbe`（iOS 原生壳）+ `Sources/PhoneDSHEngine`（`pdsh-page:` 页面源）
- 仓库 HEAD：`86a39aac`（2026-11-01，`fix: tighten composer bottom spacing`）；工作区有 Android 侧未提交改动，与本审计无关
- 方法：只读通读源码 + `grep` 调用点 + 对照 `spec/v1/render-media-v1.md`、`spec/ui/v1/pages/files.json`、`spec/platform/whitelist.json` + 盘点现有测试与截图
- **未做的事**：没有运行模拟器/真机，没有截图，没有改任何代码或 git 状态。凡属"读码推断但未运行验证"的结论都在正文标了 `[未验证]`
- 一句话结论：**预览不缺组件，缺的是入口分层。** 组件（QuickLook / PDSHPage / 等宽文本 / Markdown）都在，但一次点击要穿 2 层 modal、文本被自己截到 200 行、非工作区文件无路可走；同时仓库里还躺着两套已死的预览实现。

---

## 1. 当前实现清单

| 实现 | 位置 | 状态 | 职责 |
|---|---|---|---|
| `FilePreviewPage` | `FilesPage.swift:224-445` | **活的**，`private` | 唯一的文件预览页：4 种形态 + 失败态 |
| `EmbeddedQuickLook` | `FilesPage.swift:456-487` | 活的 | `QLPreviewController` 作为子 VC（不是 modal） |
| `PDSHPageView` / `PDSHPageWebView` | `Sources/PhoneDSHEngine/PageSurface.swift:50-213` | 活的 | HTML 页面（`pdsh-page:` origin + WKWebView） |
| `PDSHPageSchemeHandler` | `Sources/PhoneDSHEngine/PageSchemeHandler.swift:304-508` | 活的 | 页面字节源：双根 + Range + 注入 CSP |
| `SessionArtifactPreviewPage` | `SessionArtifactsPage.swift:296-349` | 活的（**另一条独立链路**） | Office 产物 → `canPreview` → 嵌入 QL |
| `WebEngineNativePreview` | `Sources/PhoneDSHEngine/WebEngineNativePreview.swift:558-868` | **死代码** | 旧 Web 面的 `pdshNativePreview` 桥；`install(on:)` 定义在 `WebEngineNativePreview.swift:593`，全仓库**没有调用点**（`grep -rn "install(on" Sources examples` 只命中定义本身 `:593` 和 `:30` 的注释） |
| `ChatModel.preview(_:)` + `previewPath/previewText` | `ChatModel.swift:2946-2957`、`ChatModel.swift:497-498` | **死代码** | 24 KiB 的第三套文本预览；没有任何 View 读 `previewText` |
| `NativeTrajectoryRow` | `ChatPage.swift:4290-4364` | **死代码** | 含"预览 path"入口，但没有任何实例化点 |

结论：`FilePreviewPage` 是**唯一**活着的通用预览器，而且被 `private` 封在 `FilesPage.swift` 里（`FilesPage.swift:224`），所以任何"别的地方想直接开预览"的写法都过不了编译，只能借 `FilesPage` 当宿主。这是后面所有绕路的根。

### 1.1 进 Files 的唯一产品入口

`FilesPage` 的**外部**实例化点只有两个（它自己递归进子目录的 `FilesPage(directory:)` 见 `FilesPage.swift:118`，不算入口）：

- `NativeWorkbenchPage.swift:24` — `FilesPage(initialPath: initialPath)`
- `NativeShell.swift:787` — `-uiPreview workspace.files`（仅 DEBUG）

`WorkspaceFoldersPage`（"工作文件夹"页，`NativeShell.swift:319-410`）**当前产品不可达**：抽屉只有"定时任务 / 设置"两行（`NativeShell.swift:298-303`），`WorkspaceFoldersPage` 的唯一实例化点是 `NativeShell.swift:786` 的 DEBUG 路由。`docs/receipts/ios-baseline-screens/REACHABILITY.md:22`（"drawer folder → NativeShell.swift:329"）已过期——那行代码现在是 `WorkspaceFoldersPage` 自己的 `NavigationLink`，而不是抽屉入口。

所以：**Files 页只能从对话页的 `⋯ → 右侧边栏`（`ChatPage.swift:259-263`）或一次文件点击进入**，两者都经过 `NativeWorkbenchPage`。

---

## 2. 当前流程与导航深度

### 2.1 图

```
[对话页 ChatPage]
  │
  │ ① 点链接/附件/工具标题            onOpenFile(path)
  │    ├ 助手 markdown 链接           ChatPage.swift:3682-3686 → openURL
  │    ├ 行内 code 命中唯一文件名       NativeMarkdownBody.swift:264-269, 309-313
  │    ├ 工具详情标题（有 location）    NativeToolDetailsCard.swift:425 / NativeToolDetailCards.swift:55
  │    ├ 改动文件卡                   NativeChangedFilesCard.swift:17, 54
  │    ├ 消息附件行                   NativeMessageRows.swift:122-130
  │    └ 工具输出里的"预览 path"按钮     ChatPage.swift:4042-4055（经 4265 / 4348）
  │
  ▼
openWorkspaceResult(path)             ChatPage.swift:2522-2550
  ├ 归一化 normalizedWorkspacePath     ChatPage.swift:2554-2568
  ├ 命中 model.files（含 NFC 规范化、唯一 basename 兜底）
  │     → initialWorkbenchPath = match.relativePath
  │       showWorkbench = true                              ChatPage.swift:2542-2543
  └ 未命中 → pendingPreviewPath = …，报"文件还在写入或同步中"  ChatPage.swift:2548-2549
        └ 文件列表变化时重试 pendingPreviewPath                ChatPage.swift:637-645
                                                              （重试也仍然只开 workbench）

┌─ Sheet A：NativeWorkbenchPage（"工作区"，.large） ────────── ChatPage.swift:382-385
│    NavigationStack                                        NativeWorkbenchPage.swift:14
│    Picker「文件 / 命令」                                    NativeWorkbenchPage.swift:16-20
│    FilesPage(initialPath:)                                NativeWorkbenchPage.swift:24
│      .task → refreshFiles() → 目录/规范化匹配 → selectedFile
│                                                          FilesPage.swift:58, 142-168
│      （列表先渲染出来，再弹下一层）                          FilesPage.swift:59-64
└──────────────────────────┬────────────────────────────────
                           ▼
             ┌─ Sheet B：NavigationStack { FilePreviewPage } ─┐
             │  QuickLook 子 VC          FilesPage.swift:297  │
             │  PDSHPageView（HTML）      FilesPage.swift:301  │
             │  NativeMarkdownBody（md）  FilesPage.swift:306  │
             │  Text 等宽（其它文本）       FilesPage.swift:307-314
             │  ContentUnavailable（失败） FilesPage.swift:315-318
             │  toolbar：完成 / 分享       FilesPage.swift:322-334
             └───────────────────────────────────────────────┘
                            ✕ 关闭 → 回到 Sheet A 的文件列表（不是对话）
```

`Workbench` 是 DSH 右侧边栏的手机版（`NativeWorkbenchPage.swift:4-5` 注释），`FilesPage` 是"浏览器"（`ChatModel.swift:841-843` 注释）。代码把"打开这个文件"实现成了"打开浏览器"，这就是那层多余 modal 的由来。

### 2.2 深度表

| 入口 | modal 层数 | 屏幕层数 | 关掉要几次 | 证据 |
|---|---|---|---|---|
| 对话里的文件链接 | **2**（workbench + preview） | 3（对话 / 工作区列表 / 预览） | 2 次下滑，或"完成"×2 | `ChatPage.swift:382-385`、`FilesPage.swift:59-64` |
| 对话 `⋯ → 右侧边栏 → 文件` | 2 | 3 | 2 | `ChatPage.swift:259-263` |
| 已经在 Files 列表里点文件 | 1 | 2 | 1 | `FilesPage.swift:124-135`、`:59-64` |
| Files 列表里的子目录 | 1 + push N 层目录 | 2+N | 1+返回 | `FilesPage.swift:116-123` |
| 对话 `⋯ → 产物`（Office） | 1 sheet + 1 push | 2 | 1 | `ChatPage.swift:453-459`、`SessionArtifactsPage.swift:99-103` |

### 2.3 为什么会有那层"多余"的层（四条硬原因）

1. `FilePreviewPage` 是 `private`（`FilesPage.swift:224`），且强依赖外层 `NavigationStack` 提供导航条、`Done`、`Share`（`FilesPage.swift:320-334`）。对话页没法复用它。
2. `openWorkspaceResult` 的状态只有 `initialWorkbenchPath` 和 `showWorkbench`（`ChatPage.swift:70-71, 2542-2543`），**没有**"待预览文件"状态。
3. `initialPath` 只能被 `FilesPage.task` 消费（`FilesPage.swift:58, 142-168`），即"进目录 + 选中行"，然后再由 `FilesPage` 自己弹 Sheet B。所以**必然先出一屏列表**。
4. 产品语义上它被写成了"打开右侧边栏"（`ChatPage.swift:260` 的菜单标题就是"右侧边栏"），文件只是侧边栏里的一栏。

---

## 3. 支持类型 × 渲染器矩阵

| 类型 | 判定依据 | 渲染器 | 字节来源 | 实际上限 | 证据 |
|---|---|---|---|---|---|
| `md` / `markdown` | 扩展名白名单 | `NativeMarkdownBody`（在外层 `ScrollView` 内） | **Worker RPC** | **200 行 / 256 KiB** | `FilesPage.swift:286-287, 305-306, 399-414` |
| `txt` `log` `yaml` `yml` `xml` `toml` `ini` `patch` `diff` `css` `swift` `py` `js` `ts` `sh` `c` `h` `go` `rs` | 同上 | 等宽 `Text` + 双向 `ScrollView` | Worker RPC（失败回落本机） | 200 行 / 256 KiB | `FilesPage.swift:286-288, 307-314, 399-426` |
| `json` `csv` `tsv` | `directTextExtensions` | **纯文本**等宽（无高亮、无表格） | **直读物化副本** | **8 MiB** | `FilesPage.swift:230-231, 374-388` |
| `html` `htm` | 同上 | `PDSHPageView`（WKWebView + `pdsh-page:` origin） | scheme handler 流式读 | 无大小上限（1 MiB 分块） | `FilesPage.swift:298-304, 363-370`；`PageSchemeHandler.swift:378, 437-491` |
| 图片 `png` `jpg` `jpeg` `gif` `webp` `heic` `svg` | **不在**白名单 → QL | `QLPreviewController`（嵌入） | 直接文件 URL | 系统能力 | `FilesPage.swift:284-288, 297, 389-398` |
| `pdf` | 同上 | QuickLook | 直接 URL | 系统能力（支持原生缩放/翻页） | 同上 |
| Office `docx` `xlsx` `pptx` | 同上 | QuickLook | 直接 URL | 系统能力 | 同上；另有一条 `SessionArtifactsPage` 走 `OfficeArtifactStore`（`SessionArtifactsPage.swift:172-187, 296-319`） |
| 视频 `mp4` `mov`、音频 | 同上（不在白名单） | QuickLook 自带播放器 | 直接 URL | 全仓库**没有** `AVKit` / `AVPlayerViewController`（grep 无命中） | `FilesPage.swift:284-288` |
| `glb` `gltf` `usdz` `zip`、无扩展名（`Makefile`、`README`）、`kt` `java` `gradle` 等 | 同上 | QuickLook，**且没有 `canPreview` 预检** | 直接 URL | 可能只显示通用文件图标，没有任何文字兜底 | `FilesPage.swift:284-288, 389-398`；`spec/platform/whitelist.json:305` 已记录该缺口 |
| 目录 | `folders` | `NavigationLink` 递归 `FilesPage` | — | — | `FilesPage.swift:39-47, 116-123` |
| 非工作区文件（`/tmp/…`、相册、其它 App） | — | **无** | — | — | `ChatPage.swift:2524-2526, 2548-2549` |

**QuickLook vs 自绘 vs 内嵌 Web，一句话版**：

- 自绘只覆盖 **26 个文本扩展名**（`FilesPage.swift:286-287` 的字面表）+ Markdown 富文本。
- 其它一切二进制都交给 **系统 QuickLook**，且是"子 VC 内嵌"而不是 modal（`FilesPage.swift:293-297` 注释解释过：在 sheet 里再弹 modal 会被 iOS 静默丢弃）。
- 只有 **HTML** 进 WKWebView；**没有任何类型**走"内嵌浏览器看 PDF/Office/视频"的路子（WebKit 那条桥是死的）。

---

## 4. 限额与失败模式

### 4.1 数字从哪来

| 数字 | 出处 | 说明 |
|---|---|---|
| 200 行 | `FilesPage.swift:227`（常量）、`:404`（`limit: 200`） | **App 自己请求的行数** |
| 256 KiB | `FilesPage.swift:226`（常量）、`:407`（`utf8Prefix` 截断） | **App 自己截的** |
| 8 MiB | `FilesPage.swift:231`（常量）、`:377`（`data.prefix`） | 只对 `json/csv/tsv` |
| 1 MiB 分块 | `PageSchemeHandler.swift:378` | HTML/资源流式读，峰值内存与文件大小无关 |
| 5000 行 / 2 MiB | `plugins/node_modules/@deepseek-ai/dsh-api-workspace-files/lib/index.js:383-388`（host API 默认 `maxLines: 5e3`、`maxBytes: 2*1024*1024`） | 仓库内**没有**找到 Swift 侧覆盖这两个值的地方 |

**代码注释和实现对不上**：`FilesPage.swift:228-231` 写"the Worker read caps at 256 KiB / 200 lines (spec-render-media-v1 §C.2)"，但仓库里 host API 的默认上限是 5000 行 / 2 MiB。也就是说 **200 行 / 256 KiB 是 App 自愿的自我限制，不是对端硬墙**。`[未验证]` 实际部署的 worker bundle 是否另配了更小的值——但即使有，App 先请求 200 行这一点也已经把上限压死了。

### 4.2 失败模式

| 场景 | 现在的行为 | 证据 |
|---|---|---|
| 文件 > 200 行（`.md`/`.txt`/`.log`/源码） | 只显示前 200 行，底部一行小字提示"仅显示前 %d 行"；**没有"加载更多"、没有跳转行号** | `FilesPage.swift:404, 412-414` |
| 文件 > 256 KiB（同上） | 截断 + 底部提示；同样无续读 | `FilesPage.swift:407-411` |
| `.json`/`.csv`/`.tsv` > 8 MiB | 截断 + 提示；UTF-8 在 8 MiB 处切断可能劈开多字节字符（`String(decoding:)` 会用 U+FFFD 顶替） | `FilesPage.swift:377-382` |
| 8 MiB 文件读取 | `Data(contentsOf:)` + `String(decoding:)` 跑在 `.task`（主 actor）上 → 卡主线程 | `FilesPage.swift:352, 374-378` |
| 文件已被删除/不可读 | 标题**永远**是"这个文件已经不在了。"，真正原因塞在副标题；HTML 分支还会把 `previewError` 整个吞掉 | `FilesPage.swift:315-318`、`:302-304` |
| 打开瞬间（首帧） | `isHTML`/`textPreview` 都是初始值 → 先闪一帧"这个文件已经不在了。"，`.task` 跑完才换成真内容；**没有任何 loading 态** | `FilesPage.swift:315-318, 352` |
| 没有当前会话 | `guard let sessionID = currentSessionID else { 报错并 return }` 在最前面，**连 QuickLook 和 8 MiB 直读也一起被挡**，而这两个根本不需要会话 | `FilesPage.swift:356-359` |
| Worker 读失败 | 回落读本机物化副本 + 提示"当前显示本机物化副本" | `FilesPage.swift:415-426` |
| 文件还没物化 | `pendingPreviewPath` 保留路径，等 `model.files` 变化重试；**重试也仍然只开 workbench**，且离开对话页就丢 | `ChatPage.swift:2548-2549, 637-645` |
| 非工作区路径（`/tmp/a.png`、`/Users/...`） | 归一化把前导 `/` 去掉变成工作区相对路径 → 先按路径找不到 → 再按**同名文件**兜底 → 可能打开**另一个同名文件**（静默错文件） | `ChatPage.swift:2554-2568, 2570-2578` |
| markdown 里的绝对路径链接 | `workspaceRelativePath` 对 `path.hasPrefix("/")` 直接 `return nil` → 走 `.systemAction`，系统打不开 `file:` → **点了没反应** | `ChatPage.swift:3682-3686, 4102-4103` |
| `dsh-resource://file/absolute/...` | 落在 `dsh/` 前缀判定里返回 nil → 同样 `.systemAction` 静默失败 | `ChatPage.swift:4086-4091` |
| 路径含 `..` | "这个路径不能预览。"（`attachmentError`，出现在输入框附近，不在预览上下文里） | `ChatPage.swift:2524-2526` |
| HTML 不在任何工作区 | `ContentUnavailableView`"这个页面不在任何工作区里"，没有文本兜底、没有"用文本打开"出口 | `FilesPage.swift:302-304` |
| `pageResolver == nil`（`Web3DLib` 资源缺失） | 走**同一个**"不在任何工作区"分支 → 文案误导 | `FilesPage.swift:265-271, 298-304` |
| 页面源解析失败 | `PDSHPageView` 自己判 `unknownSession` / `notFound` / `pathEscapesRoot` 并显示原生说明；导航失败显示底部条；页面内 `onerror` 再画一条 page 内提示条 | `PageSurface.swift:63-76, 90-99, 187-206`；`PageSurface.swift:149-176` |
| 引擎没起 / 离线 | 工作区文件是**本地**的，不需要网络；只有 RPC 首次读取会失败并回落本机副本。远程图片（markdown 里的 `http(s)` 图）需要网络 | `FilesPage.swift:415-426`；`NativeMarkdownBody.swift:353-366` |
| 3D 示例 | Files 页右上角 `cube` 按钮 → 内置 `Web3DLib/demo/spin.html`，resolver 的 `workspaceRoot` 恒为 nil（任何跨会话引用都会被拒） | `FilesPage.swift:65-96` |

### 4.3 一个已确认的隐藏失败：本地图片永远加载不出来

`NativeMarkdownBody` 里图片的本地路径解析用的是 **`ChatModel.shared.workspaceRoot` 直接拼相对路径**（`NativeMarkdownBody.swift:386-394`），但物化文件实际在 `workspaceRoot/materialized/workspace/<rel>`（`ChatModel.swift:834-843`）。差了两级目录，所以按工作区相对路径写的图片（`![](shot.png)`、`![](/dsh/workspace/shot.png)`）一律读不到 → 只剩斜体 alt 文本。这条同时影响对话里的 markdown 图片和预览里的 markdown。需要说明：这是读码结论，路径拼法可直接核对，但没跑起来验证过。

---

## 5. 样式问题

| 问题 | 证据 | 说明 |
|---|---|---|
| 硬编码纯白页底 | `FilesPage.swift:55` `.background(Color.white)` | 同一层级的其它页面已迁到 `NativePagePalette.page`（`Components.swift:237-274`；用例见 `NativeAutomationPage.swift:75`、`MCPSettingsPage.swift:100`、`PhonePermissionsPage.swift:67`） |
| 深色模式实际是坏的 | 深色可选：`NativeChatPreferences.swift:8-18`、`PhoneDSHProbeApp.swift:32-35`；全局又强制白：`NativeShell.swift:87-91` | 深色下：白页底 + 系统深色行卡片；`FilesPage.swift:108` 用固定 `ChatPage.inkSecondary`（`ChatPage.swift:1051`，`#66666B`），不是 `NativePagePalette.inkSecondary`。`[未验证]` 未在深色下截图 |
| 长行/换行 | 纯文本分支没有任何换行开关（`FilesPage.swift:307-314`）；代码块 `DSSCodeBlock` 有换行切换 + `.fixedSize(horizontal:)`（`Components.swift:156, 199-204`） | 同一屏里"代码块能横滚、纯文本不能"的不一致 `[未验证]`：外层是双轴 ScrollView 且没有 `fixedSize`，长行到底是换行还是横滚需真机确认 |
| 语法高亮 | 纯文本分支直接 `Text(textPreview)`（`FilesPage.swift:309`）；聊天里的代码块走 `NativeCodeHighlighter`（`Components.swift:200`） | 预览一个 `.swift` 文件的效果比聊天里贴同样的代码还差 |
| 表格 | markdown 预览里表格靠 `ViewThatFits` 在"网格/卡片"之间二选一（`NativeMarkdownBody.swift:144-149`） | 宽表直接降级成卡片，没有横向滚动；且整体包在 `ScrollView(.vertical)` 里（`FilesPage.swift:306`） |
| 缩放 | 全仓库没有 pinch/zoom 手势；只有 QuickLook（PDF/图片）和 WKWebView 自带缩放 | 纯文本/Markdown/表格都不可缩放 |
| 安全区 | 提示条用 `.safeAreaInset(edge: .bottom)`（`FilesPage.swift:335-351`），`.background(.bar)` | 结构没问题；但提示条是"唯一"的限额告知，被键盘/横屏挤掉就没有第二次告知 |
| 分享按钮位置 | 只在预览页 toolbar `.primaryAction`（`FilesPage.swift:326-333`）；文件行**没有** context menu（`FilesPage.swift:124-135`） | 想分享必须先开预览；`safeFileURL == nil` 时 `ShareLink` 直接消失，失败态连"导出"都没有 |
| 加载态 | 无 spinner / skeleton；首帧是"文件不存在"（`FilesPage.swift:315-318` + `:352`） | 首帧误导 + 无进度 |
| 双层 chrome | workbench 的 `Picker`（`NativeWorkbenchPage.swift:16-20`）+ `FilesPage` 的 large title（`FilesPage.swift:51-52`）+ 搜索栏（`:56`）叠在一起；两处 `navigationTitle` 声明竞争（`NativeWorkbenchPage.swift:29` vs `FilesPage.swift:51`） | 哪个生效取决于 SwiftUI 取最内层的行为 `[未验证]`；但"工作区"这个词在预览路径上永远不会出现 |
| 可能的重复分享按钮 | 嵌入的 `QLPreviewController` 自带工具条（`FilesPage.swift:456-487`） | `[未验证]` 是否和外层 `ShareLink` 重复出现 |

---

## 6. HTML / Web 预览细节

| 问题 | 结论 | 证据 |
|---|---|---|
| scheme | `pdsh-page://<sessionID>/<rel-path>`；`pdsh-page://lib/<asset>`（`lib` 为保留 host） | `PageSchemeHandler.swift:197-200`；`PageSurface.swift:34-46` |
| JS | **开**：`allowsContentJavaScript = true` | `PageSurface.swift:123` |
| 数据存储 | `.nonPersistent()`（内存态，不落盘、跨启动不保留） | `PageSurface.swift:122` |
| 宿主桥 | **没有**：不装任何 `WKScriptMessageHandler`（对比死掉的 `WebEngineNativePreview` 就是靠 message handler 通信的） | `PageSurface.swift:126-129`；`WebEngineNativePreview.swift:593-604` |
| 调试 | `isInspectable = false` | `PageSurface.swift:137` |
| 网络策略 | 三档 CSP 由宿主注入，档位由页面 `<meta name="pdsh-csp" content="sandbox|local|online">` 声明；`connect-src`：sandbox=`'none'`、local=`pdsh-page:`、online=`pdsh-page: https:` | `PageSchemeHandler.swift:248-266` |
| 档位识别 | **子串匹配前 4096 字节**，不是 HTML 解析；`name="pdsh-csp"` 与 `content="online"` 可以不相邻、可以在注释/字符串里；meta 落在 4 KB 之后就退回 sandbox | `PageSchemeHandler.swift:228-239, 455` |
| base URL / 相对资源 | 页面从自身 URL 加载，相对脚本/贴图/`.glb` 正常解析；`base-uri 'none'` 只禁 `<base>` 元素，不影响相对 URL | `PageSurface.swift:138`；`PageSchemeHandler.swift:263` |
| 跨 host 资源 | handler 回 `Access-Control-Allow-Origin: *` + `Cross-Origin-Resource-Policy: cross-origin`，所以 `pdsh-page://lib/...` 的 module/贴图可用 | `PageSchemeHandler.swift:442-447`；demo 用例 `Web3DLib/demo/spin.html:14-16, 20-24` |
| `<script type="importmap">` / ES module | 允许（CSP `script-src 'unsafe-inline' blob: pdsh-page:`） | `PageSchemeHandler.swift:254` |
| `fetch()` | sandbox 档被 `connect-src 'none'` 拦死；demo 页面自己声明 `local` 才能 fetch 本地 `.glb` | `PageSchemeHandler.swift:259`；`spin.html:6, 20-24`；`spec/v1/render-media-v1.md:186-196` |
| `XHR`/WebSocket | 同上，只有 online 档能出网，且只到 `https:` | 同上 |
| 外链点击 | **一律取消**：`decidePolicyFor` 只放行 `pdsh-page:` | `PageSurface.swift:187-195` |
| `target="_blank"` / `window.open` | **什么都不发生**：只设了 `navigationDelegate`，没有设 `WKUIDelegate`（无 `createWebViewWith`） | `PageSurface.swift:135` |
| 能不能加载 `localhost` / `127.0.0.1` | **不能**，两道独立的墙：(1) 导航策略取消非 `pdsh-page`；(2) CSP 的 `img/connect/media` 都不许 `http:`。ATS 里的 `NSAllowsLocalNetworking` + `127.0.0.1`/`localhost` 例外是给探针 loopback 用的，不进页面 | `PageSurface.swift:192-194`；`PageSchemeHandler.swift:256-259`；`Config/PhoneDSHProbe-Info.plist:141-155` |
| ATS | 没有 `NSAllowsArbitraryLoads`；只有本地网络例外。自定义 scheme 不走 ATS | 同上 |
| `localStorage` | 没被 CSP 管；但 store 是 nonPersistent，等于每次预览一份内存副本。是否真能给 `pdsh-page:` origin 配额——**没有测试、没有 receipt** | `PageSurface.swift:122`；`Tests/PhoneDSHEngineTests/` 无相关用例 |
| `crypto.subtle` / Service Worker | 自定义 scheme 不是 Secure Context 意义上的 potentially trustworthy origin → 按规范不可用。仓库无用例 | 规范推断，`[未验证]` |
| 失败反馈 | 导航失败 → 原生底部条；页面内 `onerror`/`unhandledrejection` → 页面底部条（写死 `#b45309`/`#fff8ed` 浅色） | `PageSurface.swift:149-176, 90-99` |
| 失败后重试 | **没有**重试按钮，只能关掉重进 | `PageSurface.swift:78-101` |

只允许 GET：`PageSchemeHandler.swift:385-393`（其它方法 405）。

---

## 7. 直接打开文件：现在做不到，缺什么

**结论：点一下拿不到文件。** 一次点击只能拿到"工作区列表 + 自动选中一行"，再弹一层才看到内容（`ChatPage.swift:2542-2543` → `FilesPage.swift:59-64`）。

要做到"点一下就是文件"，**最小改动集**（不含新组件，全是搬/删）：

1. `FilePreviewPage` 从 `private` 提升为 internal，并移到独立文件（或至少挪进 `FilesPage.swift` 之外），同时去掉"必须由外层 NavigationStack 提供导航条"的隐含依赖——自带宽窄合适的 `.navigationTitle`/toolbar，或由调用方包 `NavigationStack`。
2. `ChatPage` 增加 `@State private var previewFile: WorkspaceFile?`，配 `.sheet(item:)` 直接呈现 `FilePreviewPage(file:workspaceRoot:)`；`openWorkspaceResult` 命中后写这个 state，**不再**写 `showWorkbench`（`ChatPage.swift:2542-2543`）。
3. `pendingPreviewPath` 的重试（`ChatPage.swift:637-645`）改成重试"直接开预览"，而不是重开 workbench。
4. `showWorkbench` 只留给 `⋯ → 右侧边栏`（`ChatPage.swift:259-263`）这一个"浏览"入口；`NativeWorkbenchPage.initialPath` 参数随之可以删（`NativeWorkbenchPage.swift:8, 24`）。
5. 顺手清掉 `FilesPage.safeURL(for:model:)`（`FilesPage.swift:170-181`，从未被调用）和 `ChatModel.preview(_:)`/`previewText`（`ChatModel.swift:497-498, 2946-2957`）以及 `WebEngineNativePreview`（`Sources/PhoneDSHEngine/WebEngineNativePreview.swift`，无调用点、无宿主）。

**副作用检查**：改完后关预览直接回对话（现在要退 2 层）；`FilesPage` 仍然可以从侧边栏进入浏览，两条路互不依赖。

---

## 8. 现有测试与截图

| 覆盖 | 位置 | 结论 |
|---|---|---|
| `pdsh-page:` 解析 / Range / CSP / 路径逃逸 | `Tests/PhoneDSHEngineTests/PageSchemeHandlerTests.swift`（18 个 `test` 函数） | 有，且覆盖双根、跨会话、416、1 MiB 分块 |
| 死的 Web 预览桥 | `Tests/PhoneDSHEngineTests/WebEngineNativePreviewTests.swift`（21 个 `test` 函数） | 有，但测的是没人安装的代码 |
| `FilesPage` / `FilePreviewPage` / `openWorkspaceResult` / `normalizedWorkspacePath` | **无** | 全仓库 `Tests/` 里没有任何引用（只有 `examples/probe-app/...` 自身命中） |
| `QLPreviewController` 相关 | **无** | `grep -rn "QLPreviewController\|QuickLook" Tests/` 无命中 |
| 截图 | `docs/receipts/ios-baseline-screens/ios-files.png` | **只有空态**：没有文件、没有预览页、没有 workbench |
| 视觉度量 | `docs/receipts/ios-baseline-screens/VISUAL.md:231-239`（§4 FilesPage） | 只量了空列表的标题/搜索框/空态；§5 把 workbench 列为未测量 |
| `-uiPreview` 路由 | `NativeShell.swift:743, 787`（`workspace.files`） | 只能进空 Files 页，**没有**"有文件的列表"或"预览页"的调试路由，所以预览无法做截图回归 |
| 可达性台账 | `docs/receipts/ios-baseline-screens/REACHABILITY.md:22` | 已过期（见 §1.1） |

---

## 9. 差距表

| 痛点 | 证据 | 影响 | 建议方向 |
|---|---|---|---|
| 点一下文件要穿 2 层 modal，关掉还要退 2 层 | `ChatPage.swift:2542-2543` → `ChatPage.swift:382-385` → `FilesPage.swift:59-64` | 最高频动作最贵；误触即离开对话上下文 | `ChatPage` 直接 `@sheet(item:)` 呈现预览（见 §7 第 1-3 条）；workbench 只留"浏览" |
| 文本/Markdown 被截到 200 行 / 256 KiB，且无法续读 | `FilesPage.swift:227, 404, 407-414`；host 默认其实有 5000 行 / 2 MiB（`plugins/node_modules/.../index.js:383-388`） | 长 README、长日志、长源码在手机上根本读不完，只能分享出去 | 把行数提到 host 上限或分页；加"加载更多/跳行"；`.md` 与源码也走直读（像 json/csv 那样） |
| 白名单只有 26 个文本扩展名，其余全丢给 QuickLook | `FilesPage.swift:284-288`；`spec/platform/whitelist.json:305` 已记 | `Makefile`、`README`、`.kt`、`.java`、`.gradle`、`.dart` 等常见文本被当二进制 → 要么空白 QL，要么通用图标 | 改成"先嗅探 UTF-8 文本，再回退 QL"，或把白名单换成"除已知二进制外都是文本" |
| QuickLook 分支没有 `canPreview` 预检，也没有文本兜底 | `FilesPage.swift:389-398` 对比 `SessionArtifactsPage.swift:301-306`（那边有） | `.glb`/`.zip`/未知类型：进了预览页只看到空壳，且没有说明 | 对齐产物页：`canPreview` 失败 → `ContentUnavailableView` + 分享 |
| 首帧显示"这个文件已经不在了。" | `FilesPage.swift:315-318` + `:352` | 每次打开都闪一次"文件没了"，是明确的错误信息 | 加 `loading` 态（`isLoading` + `ProgressView`），失败态只在 `loadPreview` 落定后出现 |
| 没有会话就全都不能预览（连 QuickLook 也被挡） | `FilesPage.swift:356-359` | 本地文件被无关状态绑架 | 该 guard 只包住 RPC 分支（`:399-426`），QuickLook / 8 MiB 直读不需要它 |
| markdown 内本地图片永远加载不出来 | `NativeMarkdownBody.swift:386-394` 用了 `workspaceRoot`，实际在 `workspaceRoot/materialized/workspace`（`ChatModel.swift:834-843`） | 带插图的 `.md` 预览等于没有图 | 用同一条 `safeFileURL` 解析（并复用 `FilesPage.safeURL` 那套校验） |
| 非工作区路径会静默打开同名文件 / 或点了没反应 | `ChatPage.swift:2570-2578`（basename 兜底）；`ChatPage.swift:4102-4103`（绝对路径 → 系统） | 用户以为打开了 A，其实是 B；或点了没反应且无提示 | 兜底只在"唯一命中且新旧路径同级"时用；绝对路径给出明确"不在工作区内，可分享" |
| 深色模式半坏：白页底 + 固定灰字 | `FilesPage.swift:55, 108`；`NativePagePalette` 已有却没用（`Components.swift:237-274`） | 深色下白底刺眼、层级错乱；与其它页不一致 | 换成 `NativePagePalette.page / inkSecondary / hairline`，与 `NativeAutomationPage` 对齐 |
| 纯文本预览无换行开关、无高亮、无行号 | `FilesPage.swift:307-314` vs `Components.swift:199-204` | 长行/宽代码可读性低于聊天里的同一段代码 | 复用 `DSSCodeBlock`（或抽出可配置版本） |
| HTML 只能在工作区内预览，且无文本兜底、无重试 | `FilesPage.swift:298-304`；`PageSurface.swift:78-101` | 散落的 `.html` 完全打不开；页面白屏后只能退出重进 | 非工作区 → 至少给等宽源码/分享；失败条加重试 |
| CSP 档位靠前 4 KB 子串匹配，页面可自我提权到 `online` | `PageSchemeHandler.swift:228-239, 455` | agent 生成的页面写一句 `content="online"` 就能拿到 https 出网能力（数据外发面） | 解析 `<meta>` 而不是 `contains`；`online` 需宿主侧显式授权（设置项/每次确认），并向用户显示提示条 |
| 限额提示是唯一告知，且只在底部一条 | `FilesPage.swift:335-351` | 用户不知道"还能看多少"，也不知道怎么拿全文 | 提示条给可点动作（分享 / 用其它 App 打开） |
| 三套预览实现 + 死代码 | `WebEngineNativePreview.swift`（无 `install` 调用点）、`ChatModel.swift:2946-2957`、`FilesPage.swift:170-181` | 维护者容易改错那一份；测试也在测死代码 | 删死代码，或明确把 Web 桥重新挂到 `PDSHPageView` 上（spec `render-media-v1 §C.6` 也是这么说的） |
| 预览没有任何自动化测试/截图 | §8 | 任何改动都无法回归；本审计里多处只能标 `[未验证]` | 加 `-uiPreview files.populated` + `files.preview.<type>` 调试路由，纳入 `ios-baseline-screens` 流程 |

---

## 10. 必须先修（按投入产出排序）

1. **砍掉 workbench 这层**：对话里点文件直接开 `FilePreviewPage`（§7 的 1-3 条）。这是一次性结构改动，改完"点一下 = 一个文件"。
2. **数字对齐**：`md`/源码/日志别再请求 200 行；要么提到 host 上限（5000 行 / 2 MiB），要么给分页。同时把 256 KiB / 8 MiB 的截断提示改成可操作（分享）。
3. **首帧与失败态分离**：加 `loading`，别再用"这个文件已经不在了。"当默认态；失败标题按真实原因分（无会话 / 读失败 / 已删除 / 不在工作区）。
4. **补 QuickLook 的 `canPreview` 预检 + 文本兜底**（照抄 `SessionArtifactsPage.swift:296-319` 的写法），顺手把 26 个扩展名的白名单换成"嗅探文本"。
5. **修 markdown 本地图片路径**（`NativeMarkdownBody.swift:386-394`）——一行路径的 bug，影响所有带插图的 md。

紧接着（同一批但要小心）：深色配色换 `NativePagePalette`；CSP 档位改成真解析（安全项，`PageSchemeHandler.swift:228-239`）。

---

## 附录 A — 未验证项（不要在后续文档里当事实引用）

1. 纯文本预览的双轴 `ScrollView` 下，长行到底是换行还是横向滚动（无 `fixedSize`，`FilesPage.swift:307-314`）。
2. 深色模式下 Files 页/预览页的实际观感（只有代码依据，无截图）。
3. 嵌入的 `QLPreviewController` 是否与外层 `ShareLink` 出现两个分享按钮。
4. `pdsh-page:` origin 上 `localStorage` 是否可用、可用多少配额；`isSecureContext` 是否为 false。
5. workbench 里两处 `navigationTitle` 竞争后实际显示哪一个。
6. 实际部署的 worker bundle 是否覆盖了 `workspaceFiles` 的 `maxLines/maxBytes` 默认值（仓库内未见覆盖）。
7. 视频/音频在 QuickLook 子 VC 里的控制条、全屏、画中画行为（无 AVKit，无法从代码判定）。

## 附录 B — 关键行号速查

- 入口/状态：`ChatPage.swift:70-71`（`showWorkbench` / `initialWorkbenchPath`）、`:75`（`pendingPreviewPath`）、`:259-263`（右侧边栏）、`:382-385`（workbench sheet）、`:637-645`（重试）、`:2522-2550`（`openWorkspaceResult`）、`:2554-2578`（归一化/兜底）
- 预览页：`FilesPage.swift:224`（`private struct`）、`:226-231`（三个常量）、`:251-259`（`safeFileURL`）、`:265-282`（resolver/entry）、`:284-288`（QL 判定表）、`:290-319`（五分支）、`:322-334`（toolbar）、`:335-351`（提示条）、`:352-427`（`loadPreview`）、`:434-444`（UTF-8 截断）、`:456-487`（内嵌 QL）
- Files 列表：`FilesPage.swift:9-182`（列表/目录/`initialPath`/死的 `safeURL`）
- Workbench：`NativeWorkbenchPage.swift:6-40`
- 页面源：`PageSurface.swift:120-140`（WKWebView 配置）、`:187-206`（导航策略/失败）、`PageSchemeHandler.swift:66-117`（解析+校验）、`:228-266`（CSP）、`:376-491`（响应/Range/headers）
- 模型：`ChatModel.swift:317-321`（`WorkspaceFile`）、`:834-884`（工作区根/owner/map）、`:2923-2957`（`refreshFiles` + 死的 `preview`）
- 另一条链路：`SessionArtifactsPage.swift:91, 99-103, 172-187, 296-349`
