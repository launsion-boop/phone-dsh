# L28 — 基线接 iOS PR #15（`8dd17496`）的只读审计

> 范围：iOS `public/main` 的 PR #15（`8dd17496 feat: direct native preview with paging and honest states`）。
> 本车道只读：**没有 merge / rebase / checkout 分支**，仓库 `spec/**`、`Sources/**`、`examples/**`、
> `android/**` 一字未改。所有重算都在 `/tmp` 的临时 worktree / 沙箱里完成。
>
> 拓扑（重要）：`86a39aac` **不是** `8dd17496` 的祖先，两者 merge-base 是 `8374cee7`。
> `8dd17496` 的父提交是 PR13 的 merge `9d46fc3c`；我们的 `86a39aac` 是同一份 PR13 内容
> （以 `f39acd0a` + merge `e7cf3f4c` 落地）之后的小提交。
> 所以「PR13 的 9 个页面契约」在我们树里已经存在，在 PR15 的树里从未生成过——
> 这是后面算契约增量时必须先对齐工具与输入的原因（§2.1）。

---

## 0. TL;DR

1. **PR15 的实质**：把「QuickLook + `FilePreviewPage`（private，藏 `FilesPage.swift` 里）」
   换成**一个自绘全屏预览面 `PreviewSurface`（865 行）**，带 11 类格式路由、512 KiB 分页、
   有界重试与四种「诚实状态」；同时把入口从
   「Chat → Workbench → Files → Preview 两层 modal」改成 **Chat/Files 一步直达**。
2. **契约**：`spec/` 在 PR15 里**一行都没改**（`git diff 86a39aac 8dd17496 -- spec/` 为空），
   而用 PR15 自己的 extractor 跑 `--check` 会报 **23/32 份 stale**——上游 main 现在就是红的。
   用**我们当前工作树的同一套 extractor** 重算 PR15 源码：**32 份契约份数不变，6 份文件变化，
   其中只有 1 份是语义变化**（`files.json` 少了 `分享` + 一个预览用 `完成`），其余 5 份是纯
   `provenance` 行号漂移；另有 **2 条手工条目必须改行号**（`_spec-required.json` 228→231、3430→3441）。
   **没有生成任何 `preview-surface` 契约**——新表面完全在契约之外。
3. **Android**：预览只有「页面内的子状态」，且宿主**一条真实数据都没有**
   （`FilesSource(files = null)`、`FilePreviewRead` 只在测试里构造、`onShare = {}`、
   `pageSurface` 从不提供）。PR15 里的 11 类渲染器 Android **一类都没有**；分页、首帧 loading、
   有界重试、分享、HTML 页面源全部缺失。
4. **`:engine`**：`PageSchemeHandler`/`PageSurface` 是 **Swift（`Sources/PhoneDSHEngine`）不是 Rust**，
   和 `android/engine` 无共享代码，**不需要跟着改**；但 Android 侧**没有任何对等物**
   （没有页面源、没有 CSP、没有按次网络授权），且 `:engine` 的「全 App 只允许一个 WebView」不变式
   会挡住「给预览再开一个 WebView」的做法。
5. **12 张截图**：11 条 `-uiPreview` 路由 + 1 张 `files.preview.dark`（**没有对应路由**，
   无法用截图脚本复现），且 `docs/receipts/ios-baseline-screens/INDEX.md` **没有更新**。
6. **对当前 11 条分歧**：**11 条一条不少，另加 1 条新分歧**（`files / extra-action / 分享`），
   合计 **12**；`extra-section '手机 Worker 限制'` 原样保留。

---

## 1. PR15 的实质

### 1.1 `PreviewSurface` 是什么

`examples/probe-app/PhoneDSHProbe/PreviewSurface.swift`（新增 865 行）是一个
**唯一的预览目标 + 唯一的全屏预览面**：

```swift
enum PreviewTarget: Identifiable, Hashable { case workspaceFile(String) }   // :11
struct PreviewPresentation { var line: Int?; var scroll: CGFloat? }         // :30 —— 明确不进 identity
enum PreviewPathResolver { … }                                              // :37 —— 全 App 共享的路径解析
@Observable final class PreviewModel { … }                                  // :97 —— 读/分页/重试/错误
struct PreviewSurface: View { … }                                           // :230 —— 面
```

- `PreviewTarget` 只有 `.workspaceFile(path)`：**没有** artifact / bundled / tab / peek；
  行号与滚动位置是 `PreviewPresentation`，不进 target 身份（否则 `#L24` 会产生重复栈条目）。
- `PreviewPathResolver`（`:37`）做一次归一化：`file://` / `sandbox:` 前缀、百分号解码、
  `/dsh/workspace/` 前缀、`./`、NFC、去首尾 `/`；`fileURL(for:)` 再叠
  `materialized/workspace` 根 + 符号链接解析 + `..` 拒绝 + 前缀包含检查 + `isRegularFile`。
- 生命周期：`reload()`（`:119`）取消旧任务、清空、重算 kind/size；HTML 单独走 notice；
  文本/代码 `loadNextTextPage`（`:197`）。
- 工具栏（`:323`）：`关闭`（仅 modal）、HTML 专属「网络权限」菜单 + 重载、`分享`
  （`UIActivityViewController` sheet，`:317`）。

### 1.2 支持哪些格式

`PreviewKind`（`:68`）+ `URL.previewKind`（`:73`）：

| kind | 扩展名 | 渲染器 |
|---|---|---|
| `.text` | txt/log/json/jsonl/yaml/yml/xml/toml/ini/csv/tsv/**60+ 源码与配置扩展名**（含 kotlin/gradle/sql/diff/plist…） | `NativePagedTextView`（`UITextView`，等宽 13pt，可选中） |
| `.markdown` | md, markdown | `NativeMarkdownBody`（`ScrollView`） |
| `.html` | html, htm | `PDSHPageView`（`pdsh-page://` 真源 + CSP） |
| `.image` | png jpg jpeg webp heic heif bmp tiff | `UIImage(contentsOfFile:)` + `scaledToFit` |
| `.pdf` | pdf | PDFKit `PDFView`（`autoScales`，`singlePageContinuous`） |
| `.office` | doc docx xls xlsx ppt pptx pages numbers key rtf epub | `QLPreviewController` **内嵌**（`QuickLookInline`，`:592`） |
| `.video` | mp4 mov m4v | `AVPlayer` + `VideoPlayer` |
| `.audio` | mp3 m4a wav aac flac | 同一个 `VideoPlayer(player:)` 分支 |
| `.model` | glb gltf | `Web3DLib/3d-viewer.html`（three.js + GLTFLoader + OrbitControls，自动 fit） |
| `.webMedia` | gif → `<img>`；webm/ogv → `<video>` | `Web3DLib/media-viewer.html` |
| `.unsupported` | 其余（**含 `.svg`、zip、无扩展名**） | 诚实卡片：路径 + 体积 + `分享文件` |

两个兜底：
- **无扩展名/未知扩展名做 UTF-8 sniff**（`looksLikeText`，`:187`：首 4 KiB 无 NUL、可解码、
  控制字符 ≤1%），是文本就当 `.text`；
- **`.svg` 不在 image 也不在 text**，落 `.unsupported`。但 `PageSchemeHandler` 又专门给 SVG
  加了静态 CSP（§1.5）——两处口径不一致，见 §9 Q6。

### 1.3 分页怎么工作

- 页大小固定 **512 KiB**（`pageBytes`，`:112`）。
- 读：`Task.detached` 里 `FileHandle.seek(toOffset:)` + `read(upToCount:)`，
  **越界不切断多字节 UTF-8 标量**——`while 解码失败 { data.removeLast() }`（`:207-213`）。
- 追加：`text += page`，`byteOffset = offset + data.count`，`eof = data.count < pageBytes`。
- UI（`:275-292`）：已有内容且正在读 → 40pt `正在加载更多…`；`!eof` → `加载更多` 按钮
  （`arrow.down.circle`）；两者都占 40pt 并带上分隔线。
- `loadedBytes`/`totalBytes` 有记账但**没有渲染出来**（当前 UI 不显示进度）。
- Markdown 也走同一分页模型（`:165` 与 `:281` 都把 `.markdown` 算进分页/`加载更多`）。

> 对比旧实现：`FilePreviewPage` 是 md/code **200 行 + 256 KiB** 硬截断（JSON/CSV 额外走 8 MiB
> 直读），没有「加载更多」；PR15 把 200 行/256 KiB 这一整套删掉了。

### 1.4 「诚实状态」指什么

指**页面在任何一帧都不说假话**，具体是四条规则：

1. **首帧不是错误**：`isLoading && text.isEmpty` → `ProgressView("正在读取…")`（`:261`）。
   旧实现的首帧是 `ContentUnavailableView("这个文件已经不在了。")`，读之前就先撒了一次谎。
2. **写入中 = 有界等待，不是缺失**：`fileURL == nil` 时**原地重试 12 次 × 500 ms（≈6 s）**，
   期间保持 loading；超时才说「这个文件还在写入，或已不在工作区。等待同步后重试。」（`:145-161`）。
   `retry()` 把计数清零后可手动重来。
3. **失败给原因 + 重试**：`无法预览` + `error` + `重试` 按钮（`:264-270`）；
   文本页读取失败是「读取文件失败：<原因>」。
4. **不支持就给真相与出路**：路径、体积、`分享文件`（`ShareLink`，`:515-545`）；
   HTML 顶部 notice 说明「页面在本地 pdsh-page:// 源下运行；JavaScript 已启用，外部网络默认关闭」，
   并且网络授权是**本次预览**（`networkGranted`）而不是全局开关。

另外两处「诚实」也值得记：分享是**显式 share sheet**（`.sheet` + `UIActivityViewController`，
`:317`），不再依赖 QuickLook 自带的分享；HTML 页面的 `reload` 与网络授权会重建 `webReloadID`
（`:313`），CSP 随响应头注入，所以必须重载才生效。

### 1.5 `FilePreviewPage` / `EmbeddedQuickLook` 被谁取代

被 **`PreviewSurface`** 取代，两个宿主各自接一条路：

| 入口 | PR15 之前 | PR15 之后 |
|---|---|---|
| Files 列表点文件 | `.sheet { FilePreviewPage }`（`FilesPage.swift:59` 旧） | `navigationDestination(item: $previewTarget) { PreviewSurface(isModal: false) }`（`FilesPage.swift:59`）——**push**，系统返回一次回列表 |
| Chat 点文件/工具路径 | `initialWorkbenchPath` + `showWorkbench = true`（`ChatPage.swift:2542` 旧），两层 modal | `previewTarget = .workspaceFile(...)` + `.fullScreenCover`（`ChatPage.swift:389`），**一次返回回对话** |
| Office/QL | `EmbeddedQuickLook`（`FilesPage.swift` 尾部，已删） | `QuickLookInline`（`PreviewSurface.swift:592`，26 行，仅 Office 用） |

同时：
- `ChatPage.openWorkspaceResult`（`:2532`，匹配块 `:2552-2560`）不再跳 Workbench；**找不到路径时也直接开预览**，
  由 `PreviewModel` 自己等写入（`pendingPreviewPath` 的「请稍后重试」提示被删）。
- `FilesPage` 的底层背景从 `Color.white` 改成 `NativePagePalette.page`（深色可读）。
- `Components.swift` 的 `NativePagePalette.page` 从 `Color(.systemBackground)` 改为
  明暗双值 `0xFFFFFF / 0x000000`（`NativeParityTokens.color`），**这一条是全局视觉变化**，
  不只影响预览：所有用 `page` 的页面深色模式都从「系统分层」变成「纯黑」。
- `NativeMarkdownBody` 的图片解析改走 `PreviewPathResolver.fileURL`（修掉了
  `workspaceRoot` vs `workspaceRoot/materialized/workspace` 的老 bug），且现在有 `..` 与前缀校验。

### 1.6 `NativeShell.swift` +36 行加了什么

只加**截图/调试入口**，没有产品路由：

- `PreviewScreen` 新增 11 个 case（`:740-750`）：
  `files.preview.{text,markdown,html,chat,files,long,pdf,image,office,audio,3d}`；
- `body` 里 11 个分支（`:795-819`）分别挂 `PreviewDebugRoute` / `PreviewDebugChat` /
  `PreviewDebugFiles` / `PreviewDebugLong` / `PreviewDebugPDF` / `PreviewDebugImage` /
  `PreviewDebugOffice` / `PreviewDebugAudio` / `PreviewDebug3D`；
- 这些 fixture（造 txt/md/html/wav/pdf/png/rtf、12000 行 log、从 `Web3DLib/demo/cube.glb`
  复制模型）都在 `PreviewSurface.swift` 的 `#if DEBUG` 段里，`-uiPreview` 直接可跑。

`ChatPage` 同时加了 `initialPreviewTarget`（`:16`）与 `.onAppear` 注入（`:537`），
`FilesPage` 加了 `initialPath` → `previewTarget`（`:163`），都是给这些路由用的。

### 1.7 `PageSchemeHandler` / `PageSurface` 改了什么（**是 Swift，不是 Rust**）

`Sources/PhoneDSHEngine` 是 iOS 的 Swift 包（`android/engine` 是 Kotlin，两者无共享代码；
仓库里唯一的 Rust 在 `shell/`，和页面无关）。这次改动：

**`PageSchemeHandler.swift`（91 行变更）**
- `PDSHPageResolver` 新增 `networkAllowed: @Sendable (URL) -> Bool`（默认 `{ _ in false }`）——
  **按次预览**的网络授权。
- `declaredTier` 从「子串扫描前 4 KiB」改成**真的 `<meta>` 属性解析**（前 64 KiB、属性任意顺序、
  单/双/无引号），解析失败继续找下一个 `<meta>`；**默认档从 `.sandbox` 改成 `.local`**。
- 宿主策略 = `min(声明, 授权)`：`sandbox` 即使授权也保持 sandbox；`online` 必须有授权；
  `local` + 授权 → `online`（**页面永远不能自己升档**）。
- CSP 增加 `frame-ancestors 'none'`；新增 `svgContentSecurityPolicy()`（`script-src 'none'`，
  `img-src data:`，`font-src data:`），`.svg` 一律静态档。
- 测试 **+5 条**（另有 1 条改名）：属性顺序、授权只放宽资源不放宽脚本、页面不能自升 online、
  sandbox 忽略授权、SVG 静态 CSP。

**`PageSurface.swift`（62 行变更）**
- 新增 `PDSHWebMediaKind { video, image }`；
- `PDSHPageEntry` 新增 `.model(sessionID:path:)` 与 `.webMedia(sessionID:path:kind:)`，
  两者都落到 `libraryHost` 的 `3d-viewer.html` / `media-viewer.html` 并带
  `session`/`path`/`kind` query（模型/媒体仍从 `pdsh-page://<session>/<path>` 取）；
- `WKUIDelegate` 全拒：`createWebViewWith` 返回 nil（无弹窗）、`alert`/`confirm`/`prompt`
  直接完成/返回 false/nil（**页面不能弹任何 JS 面板**）。

> 这三处（页面源、CSP 档、按次授权）在 Android **完全没有对等物**，见 §3、§4。

---

## 2. 以 PR15 为基准重算契约（worktree 实测）

### 2.1 方法（为什么必须固定工具）

- 临时 worktree：`git worktree add /tmp/l28-pr15 8dd17496`（用完已删）。
- 只在 worktree / `/tmp` 跑 `spec/ui/v1/tools/extract_ios_pages.py`，**仓库 `spec/**` 未动**。
- 两套结果都算了，因为它们回答两个不同问题：

| 实验 | 输入 | 回答 |
|---|---|---|
| **A（主结论）** | 沙箱 = 当前工作树的 `spec/` + `android/.../ui` + iOS 探针树，把 iOS 源码整体换成 PR15 的（`examples/probe-app/PhoneDSHProbe`、`Web3DLib`、`Sources/PhoneDSHEngine`），**extractor/checker 用我们工作树的版本** | 「如果我们把 PR15 的 iOS 代码接进来，现有 32 份契约会变成什么」——这是唯一能和「当前 11 条分歧」对齐的算法 |
| **B（参考）** | `/tmp/l28-pr15` 纯 PR15 树 + PR15 自带 extractor | 「上游自己重算会得到什么」（含 PR13 那 9 个从未生成过的页面） |

A 的基线自检：不换 iOS 源码、只跑 checker，**复现了仓库里的 11 条新分歧**（逐字一致），
说明沙箱和工具链是可信的。

### 2.2 结果 A：32 份不变，6 份文件变，1 份语义变

```
files BEFORE/chat.json             and AFTER/chat.json differ
files BEFORE/egress-allow-list.json and AFTER/... differ
files BEFORE/files.json            and AFTER/files.json differ
files BEFORE/runtime-details.json  and AFTER/... differ
files BEFORE/settings-about.json   and AFTER/... differ
files BEFORE/workspace-folders.json and AFTER/... differ
```

| 契约 | 页源码行数 | 语义变化 | 说明 |
|---|---|---|---|
| `files` | 487 → **219** | **是** | 少了 `分享`（`share`）与预览用 `完成`：`FilePreviewPage` 被删，预览工具栏搬进 `PreviewSurface`，而**它不是 `*Page`、也不在 `FilesPage` 里**，extractor 看不到。余下 6 个 action：文件行 nav、文件夹行 button、搜索、下拉刷新、`3D 示例`、demo sheet 的 `完成`（`FilesPage.swift:70`） |
| `chat` | 4471 → 4482 | 否 | 32/60 条 provenance 行号漂移 |
| `runtime-details` | 4471 → 4482 | 否 | 12/13 条漂移（同文件） |
| `settings-about` | 1001 → 1037 | 否 | 2/3 条漂移 |
| `egress-allow-list` | 1001 → 1037 | 否 | 0 条漂移（`NativeShell.swift` 靠前的声明没被 +36 行影响） |
| `workspace-folders` | 1001 → 1037 | 否 | 0 条漂移 |

**份数不变**：32 个 pageId 一个不多一个不少，**没有 `preview-surface`**。

### 2.3 新表面在契约之外（真正的缺口）

`PreviewSurface` 的全部可交互项——`关闭`、`分享`、`重试`、`加载更多`、`网络权限`、
`重新加载页面`、不支持态的 `分享文件`——**不出现在任何契约里**。原因有三层：

1. `discover_pages` 只收 `*Page` struct（`PreviewSurface` 不叫 Page）；
2. `_inline_presented_actions` 只内联**同一文件里**的 `private` 视图（`PreviewSurface.swift` 是另一个文件、且是 `public`）；
3. `files.json` 只是「列表页」，它 push 出去的 destination 不在它的 item 列表里。

后果：**ratchet 会因为「契约少了两条」而变绿**，但功能范围反而变大了。
这正是「PR15 让分歧变多」的机制（§6）。

### 2.4 extractor 之外的两条手工条目必须改

`spec/ui/v1/pages/_spec-required.json` 是手写文件（extractor 只读它），两条 `chat` 条目
在 PR15 里行号已失效：

| 条目 | 现在 | PR15 实际 |
|---|---|---|
| `打开会话列表`（drawer 按钮的无形标签） | `ChatPage.swift:228` | **`:231`** |
| `提交回答`（`QuestionCard` 的按钮） | `ChatPage.swift:3430` | **`:3441`** |

不改的后果：checker **规则 1** 直接抛 `stale page contracts`，连 12 条分歧都算不出来
（我第一次跑就是这样卡住的）。修好后的版本放在
`proposed/spec-ui-v1-pages/_spec-required.json`（与仓库当前文件的差异**只有这两行**）。

### 2.5 上游 main 现在就是红的

在「PR15 原树 + PR15 自带 extractor」上跑 `--check`：

```
stale contracts (rerun extract_ios_pages.py): chat, runtime-details, chat-preferences, files,
mcp-settings, mcp-editor, model-provider-settings, native-agent-presets, native-automation,
native-configuration, native-device-connection, native-device-session, native-plugin-inventory,
native-settings-document, workspace-folders, egress-allow-list, settings-about, native-shortcuts,
phone-permissions, session-artifacts, sessions, settings, web-search-settings
→ 23/32 stale, exit 1
```

也就是说：**PR15 合并时没有重新生成契约**（`git diff 86a39aac 8dd17496 -- spec/` 为空）。
契约重算不能「照抄上游」，必须由我们这边统一做。

### 2.6 实验 B 的参考结论

用 PR15 自带 extractor 从 PR15 树重算：**+9 个新页面契约**（chat-preferences、
native-agent-presets、native-device-connection、native-device-session、native-plugin-inventory、
native-settings-document、native-shortcuts、phone-permissions、session-artifacts）、
**12 份改动**。但这 9 个页面在我们工作树里**早就有契约**，所以这 9 个不是 PR15 带来的增量，
是「PR13 上游漏生成」的欠账。**以工作树为基准时，增量只有 §2.2 的 6 份。**

---

## 3. Android 侧影响清单（逐项）

先给结论：**Android 有「预览的壳」，没有「预览的料」**。

`android/lib/src/main/kotlin/com/phonedsh/ui/page/FilesPage.kt`（1250 行）里确实有一套完整的
预览状态机与渲染分支（`FilePreview` sealed interface），但：

- `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshNavHost.kt:529`
  `FilesScreenState.from(FilesSource(files = null), local)` —— **宿主从未提供文件列表**；
- `FilePreviewRead` 全仓**只在测试里构造**；
- `:538` `onShare = {}` —— **分享永远是空实现**；
- `FilesPage` 的 `pageSurface` 形参（`FilesPage.kt:621`）**没有任何调用点提供**；
- `ChatRoute`（`PdshNavHost.kt:327`）**没有 `onOpenFile`**（默认 `{}`），对话里点文件什么都不发生。

| # | PR15 的能力 | Android 现状 | 差在哪 / 性质 |
|---|---|---|---|
| 1 | `PreviewTarget` + 单一预览面 + 路由 | **没有**。预览是页面内状态：`FilesLocalState.previewPath`、`WorkbenchLocalState.previewPath`；`PdshRoute` 无 `Preview` | 新建：一个 route + 一个 resolver；并把 Files / Workbench **两套**预览合成一套（Android 现在有 2 份） |
| 2 | `PreviewPathResolver`（归一化 + NFC + 符号链接 + `..` 拒绝 + 包含检查） | **没有**（只有扩展名分类） | 新建（S），必须与 iOS 语义逐条对齐，否则安全边界不同 |
| 3 | 11 类 kind 路由 + UTF-8 sniff | **部分**：`FileKind` 只有 HTML/MARKDOWN/TEXT/EXTERNAL（`FilesPage.kt:114-169`），无扩展名 → EXTERNAL | 扩：image/pdf/office/video/audio/model/webMedia；补 sniff |
| 4 | 512 KiB 分页 + `加载更多` + UTF-8 不断字 | **没有**。模型里仍是旧的 256 KiB / 200 行截断（`FilePreviewRead.textTruncated/linesTruncated`），单个滚动区 | 改模型 + 改渲染；旧 cap 要删 |
| 5 | Markdown 渲染（`NativeMarkdownBody`，本地图片走共享 resolver） | **没有渲染器**：`FileKind.MARKDOWN` 最终落到 `FilePreview.Text`（等宽文本） | 新建（M）；Android 全仓没有 Markdown 渲染实现 |
| 6 | HTML：`pdsh-page://` 源 + CSP 档 + 按次网络授权 + 禁弹窗 | **没有源**：只有一个 `pageSurface` 插槽，宿主不提供；无 `pdsh-page`、无 CSP、无授权 | 新建一整套（页面源 + 资产服务 + CSP + 授权），见 §4 |
| 7 | 图片 `UIImage` | **没有**：EXTERNAL 卡片「无法预览二进制文件」+ 体积 | 新建（S）：`BitmapFactory`/`ImageDecoder` 即可，但 HEIC/WebP 解码能力要按 API 级别确认 |
| 8 | PDF（PDFKit） | **没有**：同上卡片 | 新建（M）：`PdfRenderer`/`PdfView`，含缩放与分页 |
| 9 | Office（QuickLook 内嵌） | **没有，且宿主没能力**：Android 无系统级 QuickLook | 只能「分享出去」（依赖 #15），或将来接第三方转换；PR15 的 04 研究建议 v1 share-first |
| 10 | 视频/音频（AVKit） | **没有**：同上卡片 | 新建（M）：`MediaPlayer`/ExoPlayer + 生命周期 |
| 11 | 3D glb/gltf（three.js viewer） | **没有** | 新建（L）：要 `Web3DLib` + three.js 资产 + PDF/HTML 之外的第二套 WebView 或复用；见 §4 的不变式冲突 |
| 12 | GIF / WebM（HTML media viewer） | **没有** | GIF 可用 `ImageDecoder`（S）；WebM 要么 ExoPlayer 要么 WebView（M） |
| 13 | 首帧 `正在读取…`（不撒谎） | **没有，且是刻意按旧基线做的**：`read == null` 直接渲染「这个文件已经不在了。」（`FilesPage.kt:917` 起的 `PreviewBody`，注释明写「no separate loading body」） | 改状态机（S）+ 改文案；**这是 PR15 唯一「一眼可见」的行为翻转** |
| 14 | 写入中有界重试（12×500 ms） | **没有**：宿主读不到就直接是终态错误 | 新建（S），要放在 route/resolver 层而不是页面里 |
| 15 | 失败 + `重试` | **部分**：有原因卡片，无重试按钮 | 小改（S） |
| 16 | 不支持态 = 路径 + 体积 + 分享 | **部分**：卡片有体积，`分享` 只在 `shareable == true` 时显示，而宿主永远给 `null` | 小改 + 依赖 #17 |
| 17 | 分享（`UIActivityViewController`） | **没有**：`onShare = {}`；全仓无 `FileProvider`、无 `ACTION_SEND`/`ACTION_VIEW`、无 `startActivity` | 新建（M）：`FileProvider` + `<paths>` + Intent + `grantUriPermission` |
| 18 | HTML 网络授权菜单 + 重载 | **没有** | 新建（S，跟 #6 一起） |
| 19 | 从对话一步开预览 | **没有**：`ChatRoute` 不传 `onOpenFile`；对话里的文件路径没有落点 | 新建（M）：先有 route，再接 Chat |
| 20 | 返回语义：预览 push，一次返回回来源 | **部分**：页面内 swap，头部返回能回列表；但没有独立路由，`FilesPage` 的返回栈是自绘的 | 跟 #1 一起解决 |
| 21 | 深色：`page` 改纯黑、预览面跟随外观 | **部分**：页面用 token，理论跟随；**但没有预览态的截图/测试** | 视觉验证 + 截图（S） |
| 22 | 契约：预览相关 action 在 `files.json` 里 | **更差**：PR15 后 `files.json` 连 `分享` 都没了，Android 的 `分享` 变成 **extra-action** | 见 §6；建议新增 `preview-surface` 契约页 |
| 23 | 测试/截图：引擎 23 测 + 12 张截图 | **1 张** Files 空态截图（`ShellFilesParityScreenshotTest`，`ios-files.png`）；`FilesPageTest` 是 JVM 状态机测试，预览只测过「有 pageSurface 插槽」 | 新建预览态截图基线（M） |

> 补充：Android 的预览还有**第二份实现**——`NativeWorkbenchPage.kt` 的 `WorkbenchPreview`
> （`Pending`/`Loading`/`Text`/…，接口 `:161`、`PreviewBody` `:756`）。PR15 在 iOS 上把预览收敛成一个面；
> Android 现在是「两个面 + 都没有数据」，合并它们本身就是一项工作。

---

## 4. `:engine`（Android）要不要动

**不需要为 PR15 改动**，理由：

1. `Sources/PhoneDSHEngine/PageSchemeHandler.swift` / `PageSurface.swift` 是 **Swift**，
   只在 iOS 包里编译；`android/engine` 是 Kotlin，二者没有共享代码、没有生成物、没有协议。
2. `android/engine` 的职责是「把官方 DSH Web 应用跑起来」：`assets/worker-bundle.zip` →
   `filesDir/worker/` → `:net` 的 loopback origin → **一个** WebView（`WebViewEngine.kt`），
   和「预览工作区文件」是两件事。
3. 它现有的边界恰好是**反对**复用的：
   - `NavigationPolicy`（`android/engine/.../NavigationPolicy.kt:27-37`）只允许 loopback origin
     及其 `blob:`，**明确封掉 `file:` / `content:` / `data:` / `javascript:`**；
   - **单 WebView 不变式**：`createWebView` 里 `if (live != 1) throw IllegalStateException(
     "…§6.3-5 allows exactly one…")`（`WebViewEngine.kt:597-625`）。
     给预览再开一个 WebView 会直接撞死这条断言，需要先改协议/不变式，不是「顺手加个 WebView」。

**但**：PR15 暴露的三项能力，Android 一处都没有，且它们不该塞进 `:engine`：

| 能力 | Android 现状 | 合理归属 |
|---|---|---|
| 工作区文件页面源（`pdsh-page://` 对等物） | 无 | 新模块（如 `:page`）或扩 `:net` 的 asset responder；**不要**动 `:engine` 的 worker origin |
| CSP 档 + `<meta name="pdsh-csp">` + 按次授权 | 无（全仓无 `Content-Security-Policy`） | 同上，服务端（响应头）实现，规则要可 JVM 单测 |
| 禁弹窗 / 禁文件选择 / 禁 `frame-ancestors` | 无 | 同上，`WebViewClient`/`WebChromeClient` 侧 |

结论一句话：**PR15 的引擎改动对 Android `:engine` 是「零编译影响、全能力缺口」**；
真要补，是一项新的 WebView 宿主（或扩展 `:net` + 复用一次性的预览 WebView），
并且必须先决定「一个 App 到底允许几个 WebView」。

---

## 5. 12 张预览态截图对应什么

文件：`docs/receipts/ios-session-audit/screens/current/files.preview.*.png`（1206×2622，402pt@3x）。

| 截图 | 路由（`-uiPreview`） | 画面/证明的事 | Android 对应状态 |
|---|---|---|---|
| `files.preview.text-chat.png` | `files.preview.text` | `notes.txt` 等宽文本、可选中、标题=文件名 | `FilePreview.Text`（有），但**无分页/无首帧 loading** |
| `files.preview.markdown-chat.png` | `files.preview.markdown` | `notes.md` 渲染标题/列表/代码块（带 `swift` 语言条与复制按钮） | **没有**（Android 把 md 当等宽文本） |
| `files.preview.html-chat.png` | `files.preview.html` | 页面在 `pdsh-page://` 里跑、JS 已执行、顶部 notice | `FilePreview.Page` + `pageSurface` 插槽，但**宿主不提供 → 空白** |
| `files.preview.long-chat.png` | `files.preview.long` | 12000 行 log，底部 `加载更多`，已读第一页 | **没有**（256 KiB/200 行截断 + 无按钮） |
| `files.preview.pdf-chat.png` | `files.preview.pdf` | PDFKit 单页连续渲染，右上 `分享` | **没有**（EXTERNAL 卡片） |
| `files.preview.image-chat.png` | `files.preview.image` | `UIImage` 等比缩放（800×500 蓝色样例） | **没有**（EXTERNAL 卡片） |
| `files.preview.office-chat.png` | `files.preview.office` | RTF 经 `QLPreviewController` 内嵌渲染 | **没有**（EXTERNAL 卡片） |
| `files.preview.audio-chat.png` | `files.preview.audio` | AVKit 播放 2 s WAV | **没有**（EXTERNAL 卡片） |
| `files.preview.3d-chat.png` | `files.preview.3d` | `cube.glb` 经 three.js 渲染 | **没有** |
| `files.preview.chat-chat.png` | `files.preview.chat` | **从对话**直接进预览（`PreviewDebugChat`），验证「一次返回回对话」 | **没有**（ChatRoute 不收 `onOpenFile`） |
| `files.preview.files-chat.png` | `files.preview.files` | **从文件列表** push 预览（`PreviewDebugFiles`），验证「一次返回回列表」 | 有近似（页面内 swap + 头部返回） |
| `files.preview.dark-chat.png` | **无路由** | 深色下的 `notes.md`（与 markdown 同一 fixture，纯黑底） | 无截图/无验证 |

两条只有看了才发现的问题：

1. **第 12 张没有 `-uiPreview` 路由**：`PreviewScreen` 里没有 `files.preview.dark`，
   `PreviewScreen(rawValue:)` 对未知值返回 `nil`，会退化成「正常 shell 根页」而不是预览。
   这张图只能是用 `files.preview.markdown` + `simctl ui appearance dark` 另外拍的，
   **`scripts/ios-parity/capture.sh` 无法复现**（它强制 `appearance light`）。
2. **`docs/receipts/ios-baseline-screens/INDEX.md` 没更新**：PR15 只加了 PNG，
   manifest 里没有任何 `files.preview.*` 行，清单里仍写着「全部 light」。
   截图基线现在有一半是不可复现的孤儿。

---

## 6. 对当前 11 条分歧的影响：**11 → 12（只增不减）**

> **快照声明（重要）**：下面两组数字都是在 **2026-11-01 18:48–18:49** 的工作树快照上测的。
> 本车道运行期间（18:50 起）**另一个车道正在并发改 `spec/**`**：
> `workspace-folders.json` 被加了 `androidOnly` 的 `重试`（这条分歧会因此消失）、
> `native-workbench.json` 改了 `baselineLacks` 文案、`_android-only*.json` / `_whitelist.json`
> 也在写（18:54:48 时 `_whitelist.json` 正处于半写状态，checker 直接报
> `entry None misses 'id'`）。所以「当前多少条」会随时间下降；
> **但 PR15 带来的增量是稳定的**：它只改到 `files`（语义）+ 5 份 provenance，
> 唯一新增分歧就是 `files / extra-action / 分享`，且不会消除任何一条。

复现命令（只读）：

```bash
python3 spec/ui/v1/tools/page_structure_check.py \
  --root . --baseline spec/ui/v1/pages/_baseline.json
# 当前工作树：page-structure: FAIL (11 new divergence(s) outside the baseline)
# 换入 PR15 iOS 源码 + 重算契约后：FAIL (12 new divergence(s))
```

**11 条一条没消失**（它们和预览无关，PR15 碰不到）：

| # | page | kind | name |
|---|---|---|---|
| 1 | chat | missing-action | `完成` |
| 2 | chat | missing-action | `刷新` |
| 3 | egress-allow-list | missing-action | `恢复成默认的` |
| 4 | native-automation | missing-action | `修改计划时间` |
| 5 | native-automation | missing-action | `保存` |
| 6 | native-configuration | **extra-section** | **`手机 Worker 限制`** |
| 7 | native-device-connection | missing-section | `解除该设备的会话映射` |
| 8 | native-device-session | missing-action | `正在读取…` |
| 9 | native-plugin-inventory | missing-section | 那段英文（iPhone Worker 没有 pnpm/execa…） |
| 10 | session-artifacts | missing-action | `分享` |
| 11 | workspace-folders | extra-action | `重试` |

**新增 1 条**：

| # | page | kind | name | 原因 |
|---|---|---|---|---|
| 12 | **files** | **extra-action** | **`分享`** | PR15 删掉 `FilePreviewPage` 后，`files.json` 的 action 从 8 减到 6（`分享` + 预览用 `完成` 都没了）。Android 的 `FilesPage` 仍在预览头渲染 `分享`（`FilesPage.kt` 的 `PreviewAction(UiStrings.FILES_PREVIEW_SHARE…)`），于是变成「契约里没有、Android 有」 |

被问到的 `手机 Worker 限制`：它**仍然是 extra-section**，前后不变（基线里另有一条
`missing-section 'iPhone Worker 限制'` 是已登记的 known，方向相反：契约有、Android 没有）。

**变多的机制值得单独记住**：ratchet 是「标签集合」比较，**删契约 = 变绿**。
PR15 让功能变大、契约变小，于是凭空多一条分歧；如果将来 Android 也照 PR15 做而契约不补，
`分享`/`重试`/`加载更多`/`网络权限` 这些会继续「隐身」——不是没有分歧，是没人检查。

**两种修法，结论相反：**

- **A. 接受并登记**：把 `files/分享` 写进 `_baseline.json` → 12 条 known，CI 绿。
  代价：新表面永久无契约。
- **B.（推荐）新增 `preview-surface` 契约页**，并让 extractor 把 `PreviewSurface` 的 toolbar/状态
  动作内联进去（或给它一个 `*Page` 壳）→ `分享` 重新被契约覆盖，分歧回到 **11**，
  且 `关闭/重试/加载更多/网络权限/重新加载` 都变成可检查项。
  这也是 PR15 自己那份研究文档 `04-ux-android.md` §7 Q3 的建议
  （「Preview 应该是一个真页面，不是 embedded child」）。

---

## 7. 建议的下一步（谁、按什么顺序）

| 顺序 | 谁 | 做什么 | 为什么是这个顺序 |
|---|---|---|---|
| 1 | **契约车道（你，`spec/**` 只有你能改）** | 用**当前工作树的 extractor**（不是 PR15 自带的）重算 32 份契约；改 `_spec-required.json` 两行（228→231、3430→3441）。产物可直接取 `proposed/spec-ui-v1-pages/` | 不做这一步，checker 规则 1 直接红，后面所有数字都算不出来 |
| 2 | 契约车道 | 决定 §6 的 A/B。建议 **B**：加 `preview-surface` 页（含 5 个 action + 4 个状态），并给 `files.json` 补回「预览入口」的语义（list → preview） | 决定 CI 是 11 还是 12；越早定，Android 的页面契约越不会被反复改 |
| 3 | 契约车道 | 改 `spec/ui/v1/README.md` §1：第 52 行「预览子页 FilePreviewPage」已不存在（现在是 push `PreviewSurface`）；第 53 行「对话里点文件路径 → Workbench」已不成立（现在直达预览） | 文档和实现对不上，下一份审计会把它当 drift 再报一次 |
| 4 | **Android 车道** | **先补数据，再补像素**：workspace 列表读 + 单文件读（文本页 + 元数据）→ 一条 `Preview` 路由 → 首帧 `正在读取…` + 有界重试 | 现在 `files = null`，任何渲染器都只能渲染空气；这一步做完，`text/markdown/html` 才有意义 |
| 5 | Android 车道 | 分享（`FileProvider` + `ACTION_SEND`/`ACTION_VIEW`） | 它让 Office/未知类型**立刻有出路**，是「诚实状态」的最低成本实现；也是 PR15 `unsupportedBody` 的对等物 |
| 6 | Android 车道 | 渲染器按「便宜→贵」：图片 → 文本分页 → Markdown → PDF → 音视频 → HTML 页面源 → 3D | 前四个不需要新 WebView / 不变式变更；HTML 与 3D 才需要先解决 §4 的单 WebView 决策 |
| 7 | Android 车道 | 把 Files / Workbench **两套预览合一**，与 PR15 的「一个面」对齐 | 不合，就是两处 bug 要修两遍、两处契约要维护 |
| 8 | 截图/验收 | Android 侧把 PR15 的 11 个状态搬进 `ParityState`/screenshot harness（`files.preview.*`），并补 `dark`；iOS 侧补第 12 张的路由 + 更新 `INDEX.md` | 没有截图基线，这些状态无法回归；上游已经出现「有图无清单」 |

**不建议现在做的**：不要照抄 PR15 的 `PreviewSurface.swift`（Swift，Android 用不上）；
不要跑 PR15 自带的 extractor 覆盖我们的 `spec/`（会把 9 个已有契约退回、23 份判 stale）；
不要在 Android `:engine` 里加第二个 WebView（撞 `§6.3-5` 断言）。

---

## 8. Open questions

1. **`preview-surface` 是契约页还是 embedded child？** 建议真页（README §1 + `pages/preview-surface.json`），
   页 id 用 `preview` 还是 `preview-surface`？Android 目前没有对应文件，需要同时给
   `android.file` 指向（否则会落 `missing` 分支）。
2. **Android 二进制策略**：share-first（便宜、诚实）还是 v1 就上 PDF/图片渲染（贵）？
   PR15 的 04 研究建议 P1 share-first、P2 渲染器；但 PR15 的 iOS 实现已经把
   PDF/图片/Office/音视频全做了，Android 的「parity」要么降级解释，要么工期重估。
3. **HTML 预览要不要做？** 做的话，第二个 WebView 归谁？`§6.3-5`「一个 App 一个 WebView」
   要不要改？这是本轮唯一会动到架构决策的点。
4. **Markdown 渲染器**（Android 全仓没有）：是本车道范围，还是单独一条？
5. **契约变小**是否可接受？（`files.json` 8→6 action；新表面 0 契约）如果不接受，
   建议同步把 extractor 的内联规则扩到「跨文件、public 的 presented view」。
6. **`.svg` 到底算哪类？** `PreviewSurface` 把它归 `unsupported`，`PageSchemeHandler`
   却专门给它静态 CSP。要么 `.svg` 进 image（静态渲染），要么明确「只作为页面内资源」。
7. **第 12 张深色截图**：要不要给它一条 `files.preview.dark` 路由并进 `capture.sh`？
   `INDEX.md` 什么时候补？上游现在是「12 张图、0 行清单」。
8. **iOS 侧 `NativePagePalette.page` 改纯黑**（`Components.swift:244`）是全局变化，
   会影响所有页面深色基线；Android 的 `page` 背景是否需要同步（现在用 token）？

---

## 附录 A — 复现命令（全部只读）

```bash
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
cd ~/Desktop/TonoTeam/phone-dsh

# 0) 拓扑
git log --oneline --graph --decorate -8 --all
git merge-base 86a39aac 8dd17496              # 8374cee7（不是 ancestor）

# 1) 当前 11 条
python3 spec/ui/v1/tools/page_structure_check.py \
  --root . --baseline spec/ui/v1/pages/_baseline.json

# 2) PR15 的只读 worktree（已清理）
git worktree add /tmp/l28-pr15 8dd17496
#   纯 PR15 自检（证明上游 stale）
python3 /tmp/l28-pr15/spec/ui/v1/tools/extract_ios_pages.py --root /tmp/l28-pr15 --check

# 3) 受控实验：当前工具 + PR15 源码
rsync -a spec/ /tmp/l28-sim/ ; rsync -a android/lib/src/main/kotlin/com/phonedsh/ui \
  /tmp/l28-sim/android/lib/src/main/kotlin/com/phonedsh/
rsync -a examples/probe-app/PhoneDSHProbe /tmp/l28-sim/examples/probe-app/
rsync -a Sources/PhoneDSHEngine /tmp/l28-sim/Sources/
rsync -a --delete /tmp/l28-pr15/examples/probe-app/PhoneDSHProbe/ \
  /tmp/l28-sim/examples/probe-app/PhoneDSHProbe/
rsync -a --delete /tmp/l28-pr15/examples/probe-app/Web3DLib/ /tmp/l28-sim/examples/probe-app/Web3DLib/
rsync -a --delete /tmp/l28-pr15/Sources/PhoneDSHEngine/ /tmp/l28-sim/Sources/PhoneDSHEngine/
cd /tmp/l28-sim
python3 spec/ui/v1/tools/extract_ios_pages.py --root .          # 重算 32 份
python3 spec/ui/v1/tools/page_structure_check.py --root . \
  --baseline spec/ui/v1/pages/_baseline.json                    # 12 new
```

## 附录 B — 产物

- `proposed/spec-ui-v1-pages/files.json` — PR15 源码重算后的 `files` 契约（唯一语义变化：少 `分享`/预览 `完成`）
- `proposed/spec-ui-v1-pages/_spec-required.json` — 已修正两条手工 provenance（与仓库当前文件只差这 2 行）
- `divergences.json` — 12 条新分歧 + 17 条 known 的机器可读清单

**没有写进仓库的任何 `spec/**`、`Sources/**`、`examples/**`、`android/**`。**
