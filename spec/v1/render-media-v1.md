# 渲染与媒体能力 spec v1 — VIDEO(60s) + PAGE(HTML/3D) + PREVIEW

**状态**：draft；Part D 第 1–6 步已实现（2026-10-29），第 7 步与 Part C 的 P1 项待做  
**依据**：`main@1af0d61` 源码核查 + 2026-10-29 真机实测  
**适用**：`spec/v1/`、`Sources/PhoneDSH*`、`examples/probe-app/`、`plugins/`

---

## 0. 结论先行

1. **VIDEO 放宽到 60 秒**，预算按 75 秒留冗余；代价是单文件上限和 WAL 配额必须一起动，否则 60 秒 1080p 会正好撞在 64 MiB 上。
2. **HTML 预览现在被两层锁死**，不是"缺组件"，是**主动禁掉**的：CSP 只允许内联脚本，`connect-src 'none'`、`img-src data: blob:`，且 `baseURL = about:blank`；再加上 256 KiB / 200 行的读取上限。所以任何引用外部库、贴图、`.glb` 的页面都不可能跑起来——3D 更不可能。
3. **要 3D，必须新增一个 PAGE surface**：自定义 scheme + 双根（工作区目录 + 内置库目录）+ 三档 CSP。不是把现有 CSP 改宽就能解决，因为 `about:blank` 没有 origin，相对路径和 `fetch()` 都无处可去。

---

## 1. 现状核查（读源码，不是猜）

| 文件类型 | 现在的渲染路径 | 卡在哪 |
|---|---|---|
| pdf / docx / xlsx / pptx / zip / 图片 | `QLPreviewController`（`FilesPage.swift:283`） | 可用，但出了预览就没有任何交互 |
| txt / json / yaml / csv / log / 源码 | 等宽文本，`workspaceFiles/read` 读 | 上限 256 KiB、200 行（`:194-195`） |
| md | `NativeMarkdownBody` | 可用 |
| html / htm | `IsolatedHTMLPreview`（`:350`） | **CSP 锁死 + 无 origin + 256 KiB 截断** |
| mp4 / mov | Quick Look | 无内联播放，无控制条定制 |
| glb / gltf / usdz | 无 | 完全不支持 |

关键三行（`examples/probe-app/PhoneDSHProbe/FilesPage.swift`）：

```swift
// :363
let policy = "default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline';
              img-src data: blob:; font-src data:; connect-src 'none'; ..."
// :364
view.loadHTMLString(safe, baseURL: URL(string: "about:blank"))
// :227  needsQuickLook 的白名单里没有 glb/gltf/usdz，也没有 mp4
```

所以"预览缺组件"的准确表述是：**预览层只做了四种形态（Quick Look、纯文本、Markdown、隔离 HTML），而隔离 HTML 的隔离强度高到连 `three.min.js` 都加载不了。**

顺带一条：`plugins/phone-native-preview` 依赖 `WebHostModel` 安装 `WebEngineNativePreview`，而 PR #1 删掉了 `WebHostModel`。合并之后这个插件是**死代码**，要么一起删，要么改挂到新的 PAGE surface 上。

---

# Part A — VIDEO v1.1（60 秒 + 冗余）

## A.1 相对 v1 草案的变更

| 项 | v1 草案 | v1.1 |
|---|---|---|
| 最大时长 | 300 s | **60 s 名义，75 s 预算冗余** |
| 最大帧数 | 18000 | 4500（60 s @ 75 fps 上限） |
| 输出上限 | 64 MiB | **96 MiB**（需单文件上限提到 128 MiB） |
| 默认分辨率 | 1080p | 1080p30 @ **6 Mbps** |
| 60 s 产物 | 60 MB（贴着上限） | **约 45 MB**（留 50% 余量） |

## A.2 预算

| 资源 | 8 GiB 行 | 12 GiB 行 |
|---|---|---|
| 单会话帧池 | 64 MiB | 96 MiB |
| 单帧上限 | 8 MiB | 16 MiB |
| 最大分辨率 | 1920×1080 | 3840×2160 |
| 最大时长（名义/冗余） | 60 s / 75 s | 60 s / 75 s |
| 最大帧数 | 4500 | 4500（75 s × 60 fps） |
| 输出上限 | 96 MiB | 128 MiB |
| in-flight 帧 | 3 | 4 |
| App 进程增量 | +80 MB | +140 MB |

**必须同步的两处**：`BudgetTable` 的 app process 行（150 → 230 MB），以及 `budgets.md` §4 的单文件行（64 → 128 MiB，连带 workspace = 2×128+32 = 288 MB、VFS = 388 MB、heap = 448 MB）。

## A.3 60 秒带来的两个硬冲突

**(1) 单文件 64 MiB。** 60 s 1080p @ 8 Mbps = 60 MB，加上容器开销会溢出。二选一：

- 降码率到 6 Mbps（推荐，图形内容 6 Mbps 足够）；
- 或把单文件上限提到 128 MiB（连带 §A.2 的三行）。

**(2) WAL 256 MiB。** ~~一次 45 MB 的写入占 17.6%~~ —— 见 §A.5：产物改为落独立的 `video/` 存储，不再进 WAL，这一条冲突已消除。只剩"回读落盘时检查单文件预算"。

## A.4 编码参数建议

| 分辨率 | 码率 | 关键帧间隔 | profile |
|---|---|---|---|
| 720p30 | 3 Mbps | 2 s | H.264 High |
| 1080p30 | 6 Mbps | 2 s | H.264 High |
| 1080p60 | 12 Mbps | 2 s | H.264 High |

`AVVideoExpectedSourceFrameRateKey` 必须设置，否则 VideoToolbox 会按内容自适应，静态图会掉到极低码率、动起来再爆。

## A.5 视频产物单独占一类配额（已定）

`video/` 成为与 WAL / journal / response log 并列的第四类持久存储：

| 存储 | 配额 | 溢出规则 |
|---|---|---|
| `Library/xl/video/` | **512 MiB** | 先删 `completed` 且已回读的会话；**永不删未回读的会话**；仍超 → `Failed` |

- 编码期间产物只落在这类存储里，**不占 WAL、不占 VFS**；
- Worker `video/read` 回读、`vfs.write` 落盘之后，才按普通文件计入 workspace 与单文件预算；
- 一个会话从 `end` 到回读完成超过 10 分钟，标记 `orphaned`，可被回收；
- 配额按设备档缩放：8 GiB 512 MiB，6/4/3 GiB 384 / 256 / 192 MiB。

这样 60 秒视频的写入不再与文档抢 WAL，`§A.3(2)` 的 compaction 冲突随之消失，只保留"写盘前检查单文件预算"这一条。

## A.6 不变的部分

线协议、幂等、背压、`video/read` 回传、生命周期绑定——全部沿用 `spec-video-accelerator-v1.md` §4–§10，本次不改。

---

# Part B — PAGE surface（HTML + 3D）

## B.1 目标

让 Worker 写出的一个 HTML 目录**能像网页一样跑起来**：加载同目录的 `.js` / `.css` / 贴图 / `.glb`，用 WebGL 渲染 3D，允许内联脚本，默认不出网。

## B.2 为什么不能放宽现有 CSP

`loadHTMLString(_:baseURL: about:blank)` 的页面 **没有 origin**：

- 相对路径 `<script src="three.min.js">` 解析不了；
- `fetch('model.glb')` 直接被 origin 为空拒绝；
- WebGL 本身可以跑，但没有几何数据可渲染。

所以正确做法不是改 CSP 字符串，而是**换加载方式**：给页面一个真实的 origin。

## B.3 架构

新增 `PDSHPageSurface`（展示层）+ `PDSHPageSchemeHandler`（`WKURLSchemeHandler`）。

```
pdsh-page://<sessionID>/<relative-path>      →  该会话的 workspace 目录（只读）
pdsh-page://lib/<asset>                      →  App bundle 内的 Web3DLib（只读）
```

**跨会话读已放开（已定）**：`<sessionID>` 可以是宿主认识的任意会话，页面 A 可以直接引用页面 B 目录下的贴图或模型：

```html
<img src="pdsh-page://<other-session>/assets/logo.png">
<script type="importmap">{ "imports": { "three": "pdsh-page://lib/three.module.min.js" } }</script>
```

约束仍然保留：

- 每个 session 段单独解析，**各自做** `resolvingSymlinksInPath` 与前缀校验，禁止 `..`；跨会话不等于跨根；
- 只允许 `GET` + `Range`；不做写、不代理外网、不暴露宿主桥；
- `lib` 是保留字，不能被 session ID 占用（校验：36 位 UUID 格式）；
- 响应头带 `Content-Type`，未知走 `application/octet-stream`。

### B.3.1 资源解析顺序（已定：能力优先）

同一个路径按三级回退，**目的是让大模型和大贴图不受任何配额约束**：

| 级别 | 来源 | 代价 | 适用 |
|---|---|---|---|
| 1 | `materialized/workspace/...` 直读文件 | 零内存、支持 Range、无 4 MiB 上限 | 已落盘的 `.glb`、贴图、`.bin` |
| 2 | Worker `workspaceFiles/read` 分块流 | 走 VFS，占内存 | 刚写入、尚未物化的文件 |
| 3 | 404 + 页面内可见错误 | — | 真的不存在 |

选型理由（这是"让能力更强"的那个选项）：

- `.glb` 动辄 20–200 MB，走 VFS 会直接撞 260 MB 的逻辑上限，还要过 4 MiB 的请求体限制；
- 直读支持 `Range`，three.js 的 `GLTFLoader` 能边下边解析，首帧时间与文件大小解耦；
- 物化目录本来就是权威副本（`wal.md` §10），读它不需要新的信任假设；
- 回退到 VFS 只为了覆盖"刚写完还没物化"的几秒窗口，正常情况下永远走不到。

缓存：`(sessionID, path) → resolved URL + mtime`，TTL 30 s；命中时不再调 `workspaceFiles/stat`。

## B.4 三档 CSP（由页面声明，宿主强制）

页面里写 `<meta name="pdsh-csp" content="local">`，宿主据此注入：

| 档 | 允许 | 用途 |
|---|---|---|
| `sandbox`（默认） | 内联脚本、`pdsh-page:` 同源资源、`data:`/`blob:` 图 | 纯本地演示 |
| `local` | 上一档 + `connect-src pdsh-page:`（可 `fetch` 本地 `.glb`/`.json`） | 3D 场景 |
| `online` | 上一档 + `https:` | 显式勾选才给，界面要有提示条 |

三档都禁止：`file:`、`frame-src` 外部域、宿主桥、`window.webkit.messageHandlers`。

## B.5 3D 资源

App bundle 内置 `Web3DLib/`（总计约 **800 KB**）：

| 文件 | 体积 | 说明 |
|---|---|---|
| `three.module.min.js` | ~660 KB | r170 |
| `GLTFLoader.js` | ~60 KB | `.glb/.gltf` |
| `OrbitControls.js` | ~30 KB | 交互 |
| `RoomEnvironment.js` | ~15 KB | 默认环境光 |
| `scaffold.html` | ~4 KB | 模板，Worker 复制改 |

通过 `pdsh-page://lib/...` 提供，**完全离线**。

## B.6 支持的 3D 格式

| 格式 | 路径 | 备注 |
|---|---|---|
| `.glb` / `.gltf`（+`.bin`+贴图） | three.js `GLTFLoader` | 主推，单文件最省事 |
| `.usdz` | Quick Look / AR Quick Look | 已有系统能力，接上即可 |
| `.obj` / `.stl` | 可选 loader | P2 |

## B.7 性能预算

- WebGL2，`premultipliedAlpha: false`，`antialias` 按设备开；
- 目标：10 万三角面 @ 60 fps（A17 及以上）；
- 首帧 < 300 ms（本地文件）；
- 单页面资源总量 ≤ 64 MB，超了在 UI 上提示；
- 3D 渲染在 **WebContent 进程**，不占 App 的 150 MB，但它有自己的 jetsam 上限——scene 里不要塞 4K 贴图。

## B.8 Worker 侧约定

模型写页面时遵守三条，就能被预览直接打开：

1. 入口固定为 `index.html`；
2. 3D 库用 `pdsh-page://lib/three.module.min.js`，**不要**引 CDN；
3. `.glb` 放同目录，用相对路径引用。

模板由 `Web3DLib/scaffold.html` 提供，Worker 侧只改 `<title>`、模型路径和相机参数。

## B.9 失败与降级

| 情况 | 行为 |
|---|---|
| HTML 超过 8 MiB | 直接打开文件，不内联 |
| 引用了不存在的资源 | 页面内 `window.onerror` 捕获，底部显示缺失路径 |
| WebGL 不可用 | 回退 `sandbox` 档 + 静态首帧图 |
| Lockdown Mode | 只允许 `sandbox` 档，禁用 `online` |

---

# Part C — 预览补齐（6 项）

| # | 缺口 | 现状 | 改法 | 优先级 |
|---|---|---|---|---|
| 1 | HTML 被 CSP 锁死 | `:363` | 换 `PDSHPageSurface` | **P0** |
| 2 | 256 KiB / 200 行截断 | `:194-195` | HTML/JSON/CSV 走文件直读，不再用 `read` API 内联 | **P0** |
| 3 | 无 3D 模型 | — | PAGE surface + three.js | **P0** |
| 4 | 视频无内联播放 | Quick Look | `AVPlayerViewController`，保留 QL 作兜底 | P1 |
| 5 | CSV/TSV 只有文本 | 等宽 Text | 简单表格视图（前 1000 行，虚拟滚动） | P1 |
| 6 | `phone-native-preview` 死代码 | 依赖已删除的 `WebHostModel` | 删除，或改挂 PAGE surface | P1 |

---

# Part D — 今晚的实现顺序

现实一点：一晚上做不完 VIDEO 编码器。建议按**可见收益**排：

| 步骤 | 内容 | 文件 | 预计 |
|---|---|---|---|
| 1 | `PDSHPageSchemeHandler` + 双根 + 路径校验 | 新增 `Sources/PhoneDSHEngine/PageSchemeHandler.swift` | 1.5 h |
| 2 | `PDSHPageSurface`（WKWebView + 三档 CSP + 错误提示） | 新增 `Sources/PhoneDSHEngine/PageSurface.swift` | 1.5 h |
| 3 | FilesPage 路由：`html/htm` → PageSurface，去掉 256 KiB 限制 | `examples/.../FilesPage.swift:227-250` | 0.5 h |
| 4 | 打包 `Web3DLib/`（three + loaders + scaffold） | `examples/probe-app/project.yml` 资源段 | 0.5 h |
| 5 | 生成一个 demo 页面验证 3D | `workspace/spin.html` + `model.glb` | 0.5 h |
| 6 | VIDEO 预算常量：60 s / 75 s / 96 MiB | `Budgets.swift`、`budgets.md`、`limits.ts` | 0.5 h |
| 7 | VIDEO 协议骨架（`begin/frame/end` 的空实现 + 测试） | `Sources/PhoneDSHVideo/`、`spec/v1/video.md` | 2 h |

**今晚的目标是 1–5 全绿 + 6 完成**；第 7 步能起个头就不错。

---

# Part E — 验收清单

- [ ] `pdsh-page://` 能加载同目录 `.js` / `.png` / `.glb`，路径逃逸（`..`、符号链接）全部拒绝
- [ ] **跨会话**：页面 A 引用页面 B 的贴图成功，且 A 不能借此写到 B 的目录
- [ ] **Range**：`Range: bytes=0-1023` 返回 206 + 正确分片；200 MB 的 `.glb` 首帧不等待完整下载
- [ ] `spinning-cube` demo 在真机上 60 fps，首帧 < 300 ms
- [ ] `online` 档未勾选时，`fetch('https://example.com')` 被 CSP 拦下且页面不崩
- [ ] 10 MB 的 HTML 不再被截断（走文件，不内联）
- [ ] `video/begin` 接受 60000 ms，75 s 时返回 `EBUDGET`
- [ ] **未回读的视频会话不被回收**：塞满 512 MiB 后新的 `end` 返回 `EBUDGET`，旧会话产物仍在
- [ ] 回读落盘后，产物才计入 workspace 与单文件预算（此前 WAL 字节数不变）
- [ ] 60 s 1080p @6 Mbps 产物 ≤ 50 MB，WAL 占用可观测
- [ ] Lockdown Mode 下 PAGE 退回 `sandbox` 档

---

## 决策记录

| # | 问题 | 结论 | 日期 |
|---|---|---|---|
| 1 | `pdsh-page://` 是否允许跨会话 | **允许**，每个 session 段独立校验，`lib` 为保留字 | 2026-10-29 |
| 2 | `.glb` 走 VFS 还是直读物化目录 | **物化直读优先**，VFS 分块仅作刚写入窗口的回退（§B.3.1） | 2026-10-29 |
| 3 | 视频产物是否单独占配额 | **单独一类** `video/`，512 MiB，永不驱逐未回读会话（§A.5） | 2026-10-29 |

## 仍待定

1. `video/` 配额溢出时的回收策略要不要暴露给用户（"清理 3 个旧视频？"），还是静默回收。
2. 跨会话读是否需要一条审计记录（哪个会话读了哪个会话的文件）——若要做，记在 `journal` 还是 console 日志。
