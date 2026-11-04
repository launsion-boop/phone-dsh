# L29 — Android 文件预览：把「有壳没料」接到 PR15 的基线

> 范围：`FilesPage.kt`、`PdshNavHost.kt`、`PdshRoute.kt`、`UiStrings.kt`（仅追加）、
> `UiPageTags.kt`（仅追加）、`android/lib/.../ui/surface/preview/**`（新建）、相关 JVM/仪器测试、
> `lib/src/main/AndroidManifest.xml` + `res/xml`（FileProvider，新建）。
> **未改**：`spec/**`、`Sources/**`、`examples/**`、`plugins/**`、`shell/**`、`android/core/**`、
> `android/dsh/**`、`android/engine/**`、其他页面文件。**没有任何 git 写操作。**
> 设备：自建 AVD `l29_preview`（android-35，1080×2400@420，端口 **5656**），用完已删。
>
> **一处声明过的越界**：`app/src/main/kotlin/com/phonedsh/probe/HostShell.kt` 的
> `hostRouteNote` 是对 `PdshRoute` 的**穷尽 `when`**（无 `else`）。新增 `PdshRoute.Preview`
> 后 `:app` 必然编译失败，所以我在那里加了一条 `is PdshRoute.Preview -> null`（外加 2 行注释）。
> 这是「加一条路由」的机械后果，不是新增宿主能力；除此之外 `:app` 一个字未动。

---

## 0. TL;DR

1. **宿主能拿到文件读，字节一直在磁盘上**：`:app` 的 `workspaceRoot = File(filesDir, "xl")`
   （`ProbeEngineViewModel.kt:357`），`:core` 的 `WalPaths.materializedWorkspace` 就是
   `materialized/workspace/`。L28 缺的不是数据，是**读**。现在读在
   `PreviewFileSource`（`:lib`）里，`FilesRoute` 和 `PreviewPage` 共用同一个 source。
2. **但 App 里仍然点不进 Files 页**：`HostNavFacts.kt:167` 把 `workspaceFolders` 报成
   `WorkspaceFoldersSnapshot(writable = FactState.NO)`（没有列表）→ 工作文件夹页零行 →
   没有任何东西 push `PdshRoute.Files`。设备实测截图 + a11y 树：「宿主没有报告工作文件夹，
   无法判断有没有」。**修复是 `:app` 一行**（见 §1.4）。
3. `PreviewPathResolver` 逐条对齐（`..` 拒绝、二次前缀包含、符号链接解析、NFC、%解码、
   `file://`/`sandbox:`/`/dsh/workspace/`/`./` 前缀、`isRegularFile`），并把 iOS 的
   「nil 一律重试」拆成**四种原因**：拒绝立刻说、缺失才等 12×500 ms。
4. **诚实状态四件套齐了**：首帧 `正在读取…`；有界重试 12×500 ms（≈6 s，与 iOS 同值）；
   失败 = `无法预览` + 原因 + `重试`；不支持 = 路径 + 体积 + **按 kind 的原因** + `分享文件`。
5. `FileProvider` + `ACTION_SEND` chooser（`content://` 只暴露
   `files/xl/materialized/workspace/`），模块自带 manifest，authority = `${applicationId}.pdsh.preview`；
   设备上实测 `content://com.phonedsh.lib.test.pdsh.preview/workspace/slides.pptx` +
   `ACTION_SEND` + `FLAG_GRANT_READ_URI_PERMISSION`。
6. **渲染器 4 类**：文本（512 KiB 分页 + `加载更多`）、Markdown（自写解析器 + 共享 `CodeBlock`）、
   图片（`BitmapFactory` 采样解码）、PDF（`PdfRenderer` 逐页渲染）。
   **未做 7 类**：HTML、Office、video、audio、3D、webMedia、其余 —— 前两个/中间的都需要**第二个
   WebView** 或平台渲染器，与 `:engine` 的「全 App 一个 WebView」不变式冲突（L28 §4）；它们全部落到
   **按 kind 说明原因 + 分享**的诚实卡片。
7. 验证：`:app:assembleDebug` 绿；`:lib:testDebugUnitTest` 全绿（新增 75 条预览测试）；
   `PageTokenReferenceTest` 绿（新增 `PreviewTokenReferenceTest` 同规则约束新文件）；
   **设备上 13/13 通过**并产出 14 张截图 + `facts.txt`。

---

## 1. 第 1 步：宿主能不能拿到文件读

### 1.1 L28 的结论与这次实测

L28 §3：`FilesSource(files = null)`、`FilePreviewRead` 只在测试里构造、`onShare = {}`、
`pageSurface` 从不提供。**根因是「读」缺失，不是「数据」缺失**。

设备实测（真 App，5656）：

```
$ adb shell run-as com.phonedsh.probe ls files/xl
boot-overlay  exec  host-state.json  journal  manifest.json  materialized  wal
$ adb shell run-as com.phonedsh.probe ls -la files/xl/materialized/workspace
drwx------ 2 u0_a209 u0_a209 4096 ... .
drwx------ 4 u0_a209 u0_a209 4096 ... ..
```

目录存在（`WorkspaceLog.recover()` → `WalPaths.createDirectories()` 建的），空是因为还没有
Worker 写过文件。也就是说：**`:dsh` / `:core` 一行都不用改**，需要的是有人去 `read`。

### 1.2 现在怎么接的

新增 `android/lib/src/main/kotlin/com/phonedsh/ui/surface/preview/`：

| 文件 | 职责 |
|---|---|
| `PreviewPathResolver.kt` | 归一化 + 安全解析（见 §2） |
| `PreviewKind.kt` | 11 类 kind + 扩展名表（照抄 iOS） |
| `PreviewPager.kt` | 512 KiB 分页、UTF-8 边界、4 KiB sniff |
| `PreviewState.kt` | `PreviewState` / `PreviewStatus` / **`PreviewFileSource`** / `PreviewPolicy` |
| `PreviewSource.kt` | `WorkspacePreviewSource`（真读）+ `rememberPreviewSource()` + `PreviewWorkspace` |
| `PreviewSurface.kt` | `PreviewPage()`：四种诚实状态 + 工具栏 + 分页 footer |
| `PreviewMarkdown.kt` | `parseMarkdown` / `parseInline` + 渲染 |
| `PreviewMedia.kt` | 图片 / PDF 两个二进制 body |
| `PreviewShare.kt` | FileProvider URI + ACTION_SEND chooser + MIME 表 |

`PreviewFileSource` 只有四个 `suspend` 操作：`files()`（列表）、`resolve(path)`、
`readPage(file, offset)`、`looksLikeText(file)`。真实现在 `Dispatchers.IO` 上跑，
页面本身仍然只是 state 的纯函数（spec §3.1 rule 3 不破）。

根目录的默认值：

```kotlin
PreviewWorkspace.defaultRoot(filesDir) = filesDir / "xl" / "materialized" / "workspace"
```

`"xl"` 是 `:app` 的 `WORKSPACE_DIRECTORY`，`:lib` 看不见 `:app`，所以**重复**了一份；
`PreviewWorkspaceTest` 在测试时**读 `ProbeEngineViewModel.kt` 的源码**断言两个字符串相等，
改名会在 JVM 套件里红，不会静默把页面变空。

宿主想自己给根：`PdshNavHost(..., workspaceRoot = File)`（新参数，默认 `null` = 上面那条默认路径）。

### 1.3 状态语义没被简化

* 目录**不存在** → `files() = null` → 页面继续渲染等待态（`等待引擎连接…`），**不是**
  「还没有文件」；
* 目录**存在且为空** → 空列表 → 页面渲染「还没有文件 / 智能体做的文件会出现在这里。」
  （这才是真的空工作区）；
* 列表**读到一半失败** → 返回 `null`（不返回半棵树）。

### 1.4 仍然缺的（要 `:app` 的所有者做，我没动）

1. **工作文件夹列表**：`HostNavFacts.kt:167`

   ```kotlin
   // 现在
   workspaceFolders = WorkspaceFoldersSnapshot(writable = FactState.NO),
   ```
   Files 页的唯一入口是「工作文件夹 → 行 → push `PdshRoute.Files`」。没有列表就没有行，
   于是 App 里**点不进文件页**（设备实测：该页正文只有「宿主没有报告工作文件夹，无法判断有没有」）。
   最小修复是让 host 报一个真实文件夹（哪怕就是本机 workspace 一个）：
   `workspaceFolders = WorkspaceFoldersSnapshot(folders = listOf(WorkspaceFolder("local", "手机工作区", null)), writable = FactState.NO)`。
   这是**契约/宿主决策**（文件夹语义、id、计数），不是我能替它编的。
2. **（可选）显式传根**：`PdshNavHost(..., workspaceRoot = File(application.filesDir, "xl"))`。
   不传也对（默认值就是它），传了少一处重复。
3. **（可选）对话里点路径**：`ChatRoute` 仍然没有 `onOpenFile`（L28 第 19 项）——那需要动
   `ChatPage.kt`，是另一条车道。

---

## 2. `PreviewPathResolver` 语义对齐清单

`PreviewSurface.swift:37`–`:64` 逐条对照。每一条都有 JVM 测试（`PreviewPathResolverTest`）。

| # | iOS | Android | 测试 |
|---|---|---|---|
| 1 | `trimmingCharacters(in: .whitespacesAndNewlines)` | `trim()` | `normalize strips the four prefixes…` |
| 2 | 去 `file://` | `removePrefix` | 同上 |
| 3 | 去 `sandbox:` | 同上 | 同上 |
| 4 | `removingPercentEncoding` | **严格 `%XX` 解码**（bad escape 原样返回；`+` 不当空格） | `a malformed percent escape keeps the input`、`a+b.txt` |
| 5 | 去 `/dsh/workspace/` | 同上 | 同上 |
| 6 | 去 `./` | 同上 | 同上 |
| 7 | NFC（precomposed） | `Normalizer.Form.NFC` | `normalize is idempotent and NFC-normalized` |
| 8 | 两端去 `/` | `trim('/')` | 同上 |
| 9 | root = `…/materialized/workspace` + `resolvingSymlinksInPath` | `root.toRealPath()`（不是目录/不存在 → `NO_WORKSPACE`） | `a host with no workspace root says so` |
| 10 | 空路径 → nil | `REJECTED` | `an empty path is refused` |
| 11 | `..` 段 → nil（**触盘之前**） | 同（`relative.split('/').contains("..")`） | `a parent segment is refused in every spelling…`（含 `%2E%2E`、含 `sub/../inside.txt`） |
| 12 | 词法前缀包含 | `candidate.normalize().startsWith(root)`（Path 元素比较，`workspace-evil` 不算在内） | `a sibling directory with a shared name prefix…` |
| 13 | 解析后再次前缀包含 | `candidate.toRealPath().startsWith(root)` | `a symlink that escapes the root is refused after resolution`、`…symlinked directory…` |
| 14 | `isRegularFile` | `Files.isRegularFile` → 否则 `NOT_A_FILE` | `a directory is its own answer` |
| 15 | 符号链接指向**根内** → 允许 | 同（`alias.txt` → `real.txt`） | `a symlink that stays inside the root resolves to its target` |
| 16 | 大小来自 `resourceValues` | `Files.size(real)`（解析后） | `resolve with its measured size` |

**三处刻意偏离**（都实现为「更诚实」，都有测试钉住）：

1. **原因分四种**：`REJECTED` / `NOT_A_FILE` / `MISSING` / `NO_WORKSPACE`。
   iOS 一律 `nil`，于是「`..` 被拒」也要白等 6 秒才说同一句话。这里
   `isRetryable` 只对 `MISSING` / `NO_WORKSPACE` 为真 → 设备测试
   `aParentSegmentIsRefusedWithoutWaiting` 在 3 秒内就拿到「此文件已不在安全的本机工作区快照中…」。
2. **`eof` 用文件长度算**，不用「trim 后的字节数 < 页大小」。
   iOS 的写法在**页边界正好切在多字节标量中间**时会提前一页报 EOF（1 MB 文件丢后半）。
   `PreviewPagerTest > a page boundary inside a multi-byte scalar does not split it` 钉住。
3. **一整页非法 UTF-8 不会卡住翻页**：`PreviewTextPage.stalled` + 前进一个窗口，
   否则 iOS 的循环拿同一个 offset 永远重试。测试 `a page that starts inside a binary run…`。

另外：`looksLikeText` 的 4 KiB 窗口若切在多字节标量中间，先用「最长合法前缀」再判，
避免把正常中文文本判成二进制（参考语义的严格解码会返回 nil）。

---

## 3. 一条 `Preview` 路由

```kotlin
public data class Preview(val path: String) : PdshRoute {  // PUSH
    override val presentation: PdshPresentation = PdshPresentation.PUSH
}
```

* `PdshNavHost` 新增 `workspaceRoot: File? = null`，并新增两条分支：
  `is PdshRoute.Files -> FilesRoute(onBack, onNavigate, workspaceRoot)`、
  `is PdshRoute.Preview -> PreviewRoute(route, onBack, workspaceRoot)`。
* `FilesRoute` 现在**真的读**：`rememberPreviewSource(workspaceRoot)` + `LaunchedEffect { listing = source.files() }`，
  `onOpenFile = { onNavigate(PdshRoute.Preview(file.relativePath)) }` —— 一次 back 回列表
  （对齐 `FilesPage.swift:59` 的 push）。
* `WorkbenchRoute` 的 `onOpenFile` 也从「页内第二个预览 + host action」改成 push
  `PdshRoute.Preview` —— 对齐 PR15 把「Workbench → preview」收敛成一个面。
* 分享是路由的动作（需要 `Context`），页面拿 `onShare: (Path) -> Boolean`，
  返回 false 时页面说「没有可以接收这个文件的 App。」而不是假装分享成功。

---

## 4. 诚实状态

| 规则 | iOS | 实现 | 测试 |
|---|---|---|---|
| ① 首帧 | `:261` `ProgressView("正在读取…")` | `PreviewState.isFirstFrame` → `ReadingBody()`（`正在读取…` + 转圈），**不会**说「这个文件已经不在了」 | `PreviewStateTest > the first frame is loading…`；设备 `theFirstFrameIsReadingAndAFileThatLandsLaterAppears`（先断言 loading，再写文件，自动出现） |
| ② 有界重试 | `:148` `retryCount <= 12`、500 ms | `PreviewPolicy.RETRY_LIMIT = 12`、`RETRY_DELAY_MS = 500`，逐次 `delay`，期间保持 loading | `PreviewStateTest > the bounded wait is twelve attempts…`；设备 `aFileThatNeverLandsEndsInCannotPreviewWithRetry`（≈6 s 后 `无法预览` + `重试`，点 `重试` 后新文件被读到） |
| ③ 失败 = 原因 + 重试 | `:264`–`:270` | `FailureBody`：`无法预览` + 原因 + `重试`；`重试` 把 attempts 清零重来 | 同上 + `PreviewPolicy.next(REJECTED, 1) = Fail(…UNSAFE)` |
| ④ 不支持 = 真相 + 出路 | `:505`–`:545` | `UnsupportedBody`：`暂时不能预览这个文件` + `可以分享文件，或使用其他 App 打开。` + **按 kind 的原因** + 路径 + 体积 + `分享文件` | `PreviewStateTest > an unsupported kind states a reason…`；设备 `anOfficeFileStatesTheTruthAndSharesThroughTheProvider` |

Android 独有的「按 kind 的原因」六条（iOS 不需要，因为 QuickLook/库页面全覆盖）：
`本机没有 Office 渲染器。` / `HTML 预览需要第二个 WebView；本机只允许一个。` /
`视频播放器还没接上。` / `音频播放器还没接上。` / `3D 预览需要 WebView。` /
`这个媒体格式需要 WebView。`

体积一律走既有的 `formatFileSize`（十进制的 `ByteCountFormatter` 对等物），没有第二个格式化器。

---

## 5. 分享怎么做的

* **声明**：`lib/src/main/AndroidManifest.xml`（`:lib` 之前**没有** manifest）声明
  `androidx.core.content.FileProvider`，`android:authorities="${applicationId}.pdsh.preview"`，
  `exported=false`，`grantUriPermissions=true`。
  合并后实测：`app/build/intermediates/merged_manifest/.../AndroidManifest.xml` →
  `android:authorities="com.phonedsh.probe.pdsh.preview"`。
* **范围**：`res/xml/pdsh_preview_file_paths.xml` 只暴露 `<files-path name="workspace" path="xl/materialized/workspace/"/>`
  —— 和解析器的根**同一个目录**，所以 provider 能给的文件一定是预览能读的文件。
* **运行时**：`PreviewShare.authority(context) = context.packageName + ".pdsh.preview"`（与 manifest 同源），
  `uriFor` 用 `FileProvider.getUriForFile`，**绝不**回退 `file://`。
* **Intent**：`ACTION_SEND` + `EXTRA_STREAM` + `FLAG_GRANT_READ_URI_PERMISSION`，外面套
  `Intent.createChooser`；`ActivityNotFoundException` / `SecurityException` / provider 拒绝
  → 返回 false → 页面显示 `没有可以接收这个文件的 App。`
* **MIME**：独立于 `previewKindOf` 的一张表（`.docx` 必须是 Word 的 MIME，即使本机不能渲染）；
  未知扩展名 → `application/octet-stream`。
* **设备证据**（`docs/receipts/l29-preview/screens/facts.txt`）：

  ```
  share-intent action=android.intent.action.SEND
    type=application/vnd.openxmlformats-officedocument.presentationml.presentation
    uri=content://com.phonedsh.lib.test.pdsh.preview/workspace/slides.pptx
  ```

  以及 `tappingShareHandsTheResolvedFileToTheSeam`：点 `分享文件` → 接缝收到的是**已解析**的
  文件（符号链接已跟随、在根内），不是路由里的原始字符串。

---

## 6. 渲染器

| kind | 状态 | 实现 |
|---|---|---|
| text | ✅ | 512 KiB/页 + `seek/read` + UTF-8 边界；`LazyColumn` 按 120 行分块（**不做** 512k 字符一次性 layout，会卡死）；块内 `SelectionContainer` 可选中 |
| markdown | ✅ | `parseMarkdown`/`parseInline`（标题/段落/围栏代码/无序/有序/引用/分隔线；`**粗**`/`*斜*`/`` `码` ``/`[文](url)`），围栏走共享 `CodeBlock`（带 `复制`） |
| image | ✅ | `BitmapFactory` + `inJustDecodeBounds` 采样（最长边 2048）；失败 → `无法显示图片` |
| pdf | ✅ | `PdfRenderer` 逐页 → `ImageBitmap`，LazyColumn，宽度=屏宽-页边距；最多 12 页并明说 `只渲染了前 N 页（共 M 页）。` |
| html | ❌ | 需要 `pdsh-page://` 对等物 + 第二个 WebView；`:engine` 的 `WebViewEngine.kt:597` 断言会 throw（L28 §4）。→ 诚实卡片 + 分享 |
| office | ❌ | Android 无系统级 QuickLook；PR15 自己的研究建议 v1 share-first。→ 诚实卡片 + 分享 |
| video / audio | ❌ | 这次没做播放器（生命周期 + 通知/焦点不在本车道范围）；→ 诚实卡片 + 分享 |
| model（glb/gltf） | ❌ | three.js 页面 = WebView；同上 |
| webMedia（gif/webm/ogv） | 部分 | `gif` 走 image（**只显示第一帧**，卡片明说）；`webm`/`ogv` → WebView，未做 |
| unsupported（含 `.svg`、zip、无扩展名） | ✅ | `.svg`/zip → 诚实卡片；无扩展名/未知扩展名 → 4 KiB UTF-8 sniff → 当文本 |

---

## 7. 设备证据

AVD `l29_preview`（android-35、1080×2400@420、port 5656、`-no-window`），
`adb -s emulator-5656 shell am instrument -w -e class
com.phonedsh.ui.screenshot.PreviewSurfaceDeviceTest
com.phonedsh.lib.test/androidx.test.runner.AndroidJUnitRunner` → **`OK (13 tests)`**。

13 条：真列表、点行 push 路由、文本读取、`/dsh/workspace/`+`%E4%B8%AD` 解码到同一个文件、
Markdown 渲染、首帧 loading + 迟到文件自动出现、6 s 后 `无法预览`+`重试`+ 重试成功、
`..` 立刻拒绝、Office 真相 + provider + intent、点 `分享文件` 到接缝、>1 页 `加载更多` 且第二页后
控件消失、图片 + PDF 真解码、可读文件绝不显示失败卡。

截图（`docs/receipts/l29-preview/screens/`，1080×2400，设备 `captureToImage`）：

| 文件 | 证明 |
|---|---|
| `files-listing.png` | 文件页真的列出磁盘上的 `notes/` 与 `hello.txt`（32 bytes） |
| `preview-text.png` | 文本 body + `分享` + `已读 32 bytes / 共 32 bytes` |
| `preview-loading.png` | 首帧 `正在读取…`（不是「已经不在了」） |
| `preview-late-arrival.png` | 同一个页面，文件在重试窗口里写好后自动出现 |
| `preview-failed.png` | `无法预览` + 「这个文件还在写入，或已不在工作区…」+ `重试` |
| `preview-refused.png` | `..` 被拒（安全边界那句话） |
| `preview-markdown.png` | 标题/加粗/行内码/列表/围栏代码（含 `复制`） |
| `preview-image.png` | 320×200 PNG 解码显示 |
| `preview-pdf.png` | `PdfDocument` 生成的真 PDF 经 `PdfRenderer` 渲染 |
| `preview-unsupported.png` | `暂时不能预览这个文件` + Office 原因 + 路径 + `17 bytes` + `分享文件` |
| `preview-paged.png` | `加载更多` + `已读 524 KB / 共 528 KB` |
| `preview-paged-end.png` | 读完第二页后 `加载更多` 消失、`已读` 前进 |
| `preview-encoded-path.png` | `/dsh/workspace/%E4%B8%AD%E6%96%87%20%E5%90%8D.txt` → 「编码测试」 |
| `app-workspace-folders.png` | **真 App** 的工作文件夹页：零行 + 「宿主没有报告工作文件夹，无法判断有没有」→ §1.4 的阻塞 |

`facts.txt` 逐条记录了每次截图的名字/尺寸/路径，以及那条 share intent。

---

## 8. 验证

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
cd android

./gradlew :app:assembleDebug              # BUILD SUCCESSFUL
./gradlew :lib:testDebugUnitTest          # BUILD SUCCESSFUL（新增 75 条预览 JVM 测试）
./gradlew :lib:assembleDebugAndroidTest   # BUILD SUCCESSFUL

# 只打 5656（connectedDebugAndroidTest 会跑所有在线设备，这里用 adb 钉一台）
adb -s emulator-5656 install -r -t lib/build/outputs/apk/androidTest/debug/lib-debug-androidTest.apk
adb -s emulator-5656 shell am instrument -w \
  -e class com.phonedsh.ui.screenshot.PreviewSurfaceDeviceTest \
  com.phonedsh.lib.test/androidx.test.runner.AndroidJUnitRunner   # OK (13 tests)
```

新增 JVM 测试（`lib/src/test/kotlin/com/phonedsh/ui/surface/preview/`）：
`PreviewPathResolverTest`(16) / `PreviewPagerTest`(13) / `PreviewKindTest`(7) /
`PreviewStateTest`(11) / `PreviewMarkdownTest`(13) / `PreviewWorkspaceTest`(7) /
`PreviewShareTest`(3) / `PreviewTokenReferenceTest`(5)。

`PageTokenReferenceTest` 未改、仍绿。新文件不写裸 `N.dp`/`N.sp`/`Color(0x…)`，
由新的 `PreviewTokenReferenceTest` 用同一套正则 + `tokens.json` 约束（含「每行第 2 行是 SPDX」）。

---

## 9. 契约侧要接的（给写 `spec/**` 的车道）

我按 checker 自己的提取器跑了一遍（**只读**，没有写 `spec/`）：

```python
m.android_actions(text, masked_kotlin(text), load_uistrings(root), consts, wrappers=…)
# → labels: ['重试', '分享文件', '分享', '加载更多']
# → sections: []
```

* **建议的页**：`pages/preview-surface.json`，`android.file =
  android/lib/src/main/kotlin/com/phonedsh/ui/surface/preview/PreviewSurface.kt`，
  `android.screen = "PreviewPage"`（文件里是 `public fun PreviewPage(`）。
* 可提取的 **4 个 action 标签**：`分享`、`重试`、`加载更多`、`分享文件`。
* **没有 section**（一个 body，没有分组标题）；如果契约要 four-state，
  建议用 `states` 而不是 `sections`——四个状态都用 tag 区分：
  `pdsh.preview.{loading,failed,unsupported,text,markdown,image,pdf,retry,share,share.file,load.more,loading.more,notice,progress}`。
* **`files.json` 的那条 `分享` extra-action 仍在**：我没有删 `FilesPage` 的页内预览
  （它现在在 App 里已经不可达，但代码和测试还在）。下一步建议是**删掉 `FilesPage.kt` 的
  `FilePreview`/`PreviewBody`/`previewNotice`/`shareable`/`pageSurface` 与它的
  `分享`/`完成` 两个 toolbar 动作**——那会同时把 L28 的第 12 条分歧（`files / extra-action /
  分享`）变绿，并真正实现「一个面」。这是独立的一次手术（还要改 `FilesPageTest`），
  我没在这次一并做，避免把两条改动混在一起。

---

## 10. Open questions

1. **App 里怎么点进文件页**（§1.4）：要 host 报什么文件夹？本机 workspace 一个就够，还是
   真的做多文件夹？契约侧 `workspace-folders.json` 会不会因此变？
2. **`FilesPage` 的页内预览什么时候删**（§9 最后一段）？删了 `files.json` 的 `分享` 是否
   同时补 `preview-surface.json`，让分歧从 12 回到 11？
3. **HTML / 3D / webMedia 的第二个 WebView 要不要开**：这是 L28 §4 的唯一架构决策点。
   在那之前这三类都是「诚实卡片 + 分享」。
4. **音视频**：`MediaPlayer`/ExoPlayer 需要生命周期、音频焦点、后台策略；本车道没做，
   要不要单开一条？
5. **文本可选中**：现在是「每 120 行一个 `SelectionContainer`」，跨块选择不行（`LazyColumn`
   的分块是性能换来的：512 KiB 一次性 layout 会卡）。要不要换成一个可选的「只读全文视图」？
6. **PDF 12 页上限**是拍的（避免 OOM）。契约/验收要不要一个明确值？
7. 过程记录：第一次用 `:lib:connectedDebugAndroidTest` 跑设备测试时，AGP 在**所有在线
   emulator** 上都跑了一遍（5556/5558 也在列），随后我改成 `adb -s emulator-5656 shell am instrument`
   钉一台；那两个设备上的测试 APK 已被 AGP 自动卸载（`pm list packages` 已确认没有
   `com.phonedsh.lib.test`）。5656 的 AVD 已删。
