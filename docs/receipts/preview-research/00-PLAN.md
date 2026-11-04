# 预览器 v1 方案（Kimi / GLM 评审后收敛）

> 依据：[01 当前 iOS](01-current-ios.md)、[02 官方 DSH](02-official-dsh.md)、[03 iOS 平台](03-ios-platform.md)、[04 UX/Android](04-ux-android.md)。  
> 外部评审：Kimi K3.1 Pro、GLM 5.3（只读方案评审，未 checkout DSH）。  
> 产品决定：**只做 session 内直接点开；一次只开一个预览；不做 tabs/多预览；产物预览后续迭代；工作区 HTML 的 JavaScript 默认开；其他按最佳体验收敛。**

## 0. 评审结论

两位评审都同意方向，但都要求 **v1 再砍一半**：

- 统一 `PreviewTarget → PreviewRouter → PreviewSurface` 是对的。
- **删掉 tab strip、artifact/bundled target、peek、CSV 网格、GLB、localhost 面**。
- JS 默认开可以，但安全边界必须是 **CSP/egress**，不是关 JS；两档 + “本次允许网络”横幅。
- 深色/Dynamic Type 从 P1 提到 P0（用户感知最强、改动便宜）。
- SVG 不能走 ImageIO；未知文件要走 “UTF-8 sniff + 元数据 + 分享”，不能只看扩展名。
- 验收缺口：当前预览 **零测试、零截图**，必须补 `-uiPreview files.*`。

## 1. 当前问题（证据）

1. **一次点击两层 modal**：Chat → Workbench → Files → Preview。`FilePreviewPage` 是 `private`，ChatPage 没有预览状态；关掉预览回到文件列表，不是对话。
2. **文本自截断**：md/code/log 200 行 / 256 KiB，无“加载更多”；只有 JSON/CSV 8 MiB。
3. **第一帧是错误态**：先显示“这个文件已经不在了”，再开始读。
4. **类型靠 26 个扩展名**：Makefile/README/.kt/.glb/.zip 落到 QL，没有文字/元数据兜底。
5. **Markdown 图片路径错**：用 `workspaceRoot`，实际在 `workspaceRoot/materialized/workspace`。
6. **HTML/JS 误解**：JS 已开；问题是 CSP 只看前 4 KiB、非 `pdsh-page` 导航全取消、没有 reload/网络授权/弹窗策略。
7. **没 loading、没分享兜底、深色半坏**。
8. **Android 只有骨架**：无单文件 read、无 HTML WebView、无 share/Intent。

## 2. v1 范围（最终）

### 2.1 只保留一个 target

```swift
enum PreviewTarget: Hashable {
    case workspaceFile(path: String)
}
```

- 行号/滚动位置/源码切换是 **presentation parameters**，不是 target 身份；否则 `#L24` 会生成重复栈条目。
- 删掉 `artifact(id:)` / `bundled(path:)`；产物预览后续迭代。
- 一次只开一个预览；**没有 tab strip、没有多预览、没有 peek**。
- 从预览里打开另一个文件：**替换当前内容**；v1 不做内部历史，系统 back 直接回到来源（Chat/Files）。这是“不做多个”的最简实现。

### 2.2 一条路由

```text
Chat 文件/附件/工具输出 ─┐
Files 列表行 ───────────┼─► PreviewRouter.open(.workspaceFile)
产物（后续） ───────────┘
                              │
                              ▼
                    PreviewSurface（全屏 push）
                    ├ header: 文件名 · 类型 · 分享 · 打开方式 · reload(HTML)
                    ├ body: 对应 renderer
                    └ state: reading / ready / failed / unsupported
```

- **PreviewSurface 永远 push 在页面级 NavigationStack**，不套在 `.sheet` 里；这才是“1 back 回来源”的保证。
- Chat 里点文件 **不再开 Workbench**；Files 列表 **不再自己 `.sheet` 预览**。
- Workbench 只保留自己的入口（文件/命令），不再承担“打开文件”的语义。

### 2.3 Router 与异步

- Router 只做同步解析：路径归一化、NFC/NFD、workspace 归属、session UUID 校验、安全路径。
- **唯一** workspace resolver；删掉 Markdown/Files/Chat 三份近似实现。
- 写入中/未知路径交给 `MaterializationWatcher`：有界重试（约 15 s），显式 `正在等待文件写入…` + 取消；**唯一 basename 兜底只能用于写入中，不能静默打开同名错误文件**。
- 生命周期：
  - session 删除 → dismiss + toast；
  - 文件删除 → 保留最后内容 + banner + reload，不自动 dismiss；
  - 后台 WebContent kill → 只重建一次 + “已重新加载”；
  - 预览页禁用 WebView 的 back-forward swipe，避免和系统返回打架。

## 3. Renderer 矩阵（v1）

| 类型 | v1 renderer | 说明 |
|---|---|---|
| txt/log/yaml/xml/toml/ini/diff/patch + 源码 | 分页等宽 `UITextView` | 2 MiB / 5000 行一页，`加载更多`，行号、`#L24`、选中复制；后台线程读取，不阻塞主线程 |
| md/markdown | Markdown + 分页源码切换 | 修 `materialized/workspace` 图片；链接/表格/代码 |
| html/htm | `pdsh-page://` WKWebView | JS 默认开；两档 CSP；reload；错误条；弹窗/下载拒绝 |
| json/csv/tsv | 分页文本 | v1 不做表格；先保证完整可看 |
| png/jpg/gif/webp/heic | ImageIO | 缩放、双击、深色背景 |
| svg | **static 档 WebView 或 QuickLook** | ImageIO 不能栅格化 SVG |
| pdf | PDFKit `PDFView` | 内联缩放/翻页/搜索；大文件/加密回退 QL |
| docx/xlsx/pptx/iWork | QuickLook 全屏 | 从最顶层 VC present，不内嵌子 VC |
| mp4/mov/mp3/m4a/wav | AVKit | 内联播放，ambient audio |
| zip/二进制/未知 | 元数据页 | 名称/大小/类型/路径 + 分享/打开方式；UTF-8 sniff 后能当文本就当文本 |
| glb/gltf | **v1 不做** | 后续 P2；不要为它引入 three.js |
| usdz | QuickLook / AR | 系统能力 |

所有状态都必须有 **分享**，包括 failed/unsupported；分享不依赖 renderer。

## 4. HTML / JavaScript 模型

JS 默认开，但真正边界是 CSP：

- **两档**：
  - `static`：无脚本、无网络，仅静态 HTML/CSS/内联图片；
  - `interactive`：脚本 + 同源 `fetch`/module（支持就开）+ WebGL；`connect-src` 只允许 `pdsh-page:`。
- 默认 `interactive`。`<meta name="pdsh-csp">` 是**请求**，不是升级；effective = min(meta, host policy)。用完整 `<head>` tokenizer 解析（最多 64 KiB），禁止前 4 KiB 子串匹配。
- 远程网络：默认禁；页面尝试外部请求时，底部一次性横幅“此页面尝试加载网络内容 · 本次允许”。仅本次预览放宽 `img/font/media/connect` 到 `https:`；**`script-src` 永不加 `https:`**，远程脚本一律不放行。不做全局设置迷宫。
- CSP 由 scheme handler 响应头注入；页面只能加严；`frame-ancestors 'none'`；SVG 也注入。
- 无 JS 桥、无 App token；`nonPersistent()` store；弹窗/下载/文件选择/摄像头/麦克风/自动播放全拒；外链确认后 `SFSafariViewController`。
- 主框架非 `pdsh-page` 导航 `.cancel` + 提示；`target=_blank` 由 `WKUIDelegate` 接住。
- **Service Worker 不支持**：检测到 `navigator.serviceWorker` 缺失时给降级说明，不承诺 PWA 离线。

## 5. localhost（v1.1，不进 v1）

- 真机上 `127.0.0.1` 是手机自己，v1 形态没有可预览服务；模拟器里的“localhost 能跑”不是产品价值。
- v1 聊天里的 `http://localhost:*` 链接：按普通外链处理（确认 → Safari），并埋点统计。
- v1.1 再做独立 Web 面：`127.0.0.1 / localhost / ::1`，独立 WKWebView/data store、origin 白名单、无桥/token、10 s 超时、“本机服务”标识；不做 mDNS/LAN/端口扫描。
- 不加 `NSAllowsArbitraryLoads`；不给 localhost 加 local-network 权限；ATS 保留 loopback 例外并补 `::1`。

## 6. UX

- Chat 文件：**1 tap → preview，1 back → Chat**。
- Files：**1 tap → preview，1 back → Files**。
- 第一帧：`正在读取…` + 文件名/大小；没有假错误态。
- Header：文件名（短）、类型 chip、分享、打开方式、HTML reload；**没有 tab strip**。
- 失败分类：not-found / no-session / read-failed / unsupported / too-large / encrypted / service-down；各有重试/分享/打开方式。
- 深色：`NativePagePalette`，不硬编码白底；Dynamic Type 基础同步做。

## 7. P0 / P1

### P0（必须，约 2–3 周）

1. `PreviewTarget` / `PreviewRouter` / `PreviewSurface`；Chat 直接打开；Files 直接 push。
2. loading、错误分类、分享兜底、1 back。
3. 唯一 workspace resolver；修 Markdown 图片；删三套死预览代码。
4. 文本分页（2 MiB/5000 行）+ `#L24`；后台读取；10k 行性能测试。
5. 类型路由：binary denylist + UTF-8 sniff + `canPreview` + 元数据页；删 26 扩展名白名单。
6. 深色 + `NativePagePalette` + Dynamic Type 基础。
7. `-uiPreview files.populated` / `files.preview.<type>` + 截图基线。

### P1（fast follow）

1. HTML 两档 CSP、reload、错误条、弹窗/下载策略、网络授权横幅。
2. PDFKit、AVKit、SVG static 档。
3. QuickLook 全屏 Office + 打开方式。
4. 文件删除/session 删除/WebContent kill 生命周期收口。
5. `#L` 定位、预览内搜索、滚动恢复。

### P2 / 后续

- localhost 独立 Web 面（与 LAN 预览一起）。
- CSV 表格、GLB/three.js、Office→PDF、预览内 tab/历史、Android 单文件 read + WebView + FileProvider。
- 产物预览单独迭代。

## 8. 决策表（已定）

| # | 问题 | 决定 |
|---|---|---|
| 1 | JS 默认 | **开**；两档 CSP，远程网络一次性授权 |
| 2 | v1 多预览 | **不做**；单 surface，replace-in-place |
| 3 | 产物预览 | **后续迭代**，不进 v1 |
| 4 | localhost | **v1 不做**，v1.1 独立面 |
| 5 | SVG | static WebView / QL，不走 ImageIO |
| 6 | GLB / CSV 网格 | P2；v1 CSV 分页文本 |
| 7 | Office | 全屏 QuickLook + 打开方式 |
| 8 | 深色/AX | P0 |

## 9. 验收

1. Chat 文件 1 tap → preview，1 back → Chat；Files 同理。
2. 第一帧必为 `reading`；错误只在读取结束后出现。
3. 10k 行日志：首屏 <300 ms、加载更多到 EOF、内存有界。
4. Markdown 本地图片 fixture 真能显示。
5. HTML：JS/module/同源 fetch 通过；meta `online` 不授权网络；弹窗/下载被拒；远程 `script-src` 永不生效。
6. session 删除 → dismiss+toast；文件删除 → stale+banner；后台 kill → 恰好一次重建。
7. zip/未知 → 元数据 + 可分享，失败态也可分享。
8. 深色截图覆盖 text/md/html/image/pdf/office。

## 10. 明确不做

- 不承诺 Service Worker/PWA 离线。
- 不加 `NSAllowsArbitraryLoads*`；不为 localhost 加 local-network 权限。
- 不把 localhost 页面嵌进 `pdsh-page://` iframe 当同源。
- 不给页面 JS 桥/App token。
- 不依赖 iOS inline QuickLook。
- v1 不做 tabs/多预览/artifacts/peek/CSV 网格/GLB/mDNS/LAN。
