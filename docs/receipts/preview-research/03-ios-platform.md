# 03 — iOS 平台能力：一个强原生预览器需要什么（只读研究）

- 研究对象：iOS 26 目标下的 WKWebView / WebKit 加载路径、原生渲染框架、ATS 与本地网络权限
- 仓库 HEAD：`86a39aac`（2026-11-01）；工作区有 Android 侧未提交改动，与本文件无关
- 本文件**未改**任何 app 代码、`Info.plist`、entitlements 或 git 状态
- 实测环境：macOS 26.3.1（25D771280a）+ Xcode 26.5（17F42）+ iPhoneOS 26.5 SDK + iOS 26.5 模拟器 runtime（`iPhone 17 Pro`，`23F77`）
- 实测方式：仓库外 `/tmp/pdsh-preview-probe` 的一个**一次性** WKWebView 探针 app（手写 `Info.plist`，`swiftc -parse-as-library` 直接编 `.app`，见附录 A），不是仓库里的 app，也没有复用仓库二进制
- 证据标记：**[实测]** = 本次在 iOS 26.5 模拟器上量到；**[SDK]** = 从 `iPhoneOS26.5.sdk` 头文件逐行核对；**[文档]** = Apple 官方文档；**[推断]** = 由上述证据推出但未单独验证；**[未验证]** = 没跑过，后续文档不要当事实引用

> 本文与 `01-current-ios.md`（现状审计）、`02-official-dsh.md`（官方 DSH 渲染链）、`04-ux-android.md`（Preview v1 交互契约）配套。**平台结论以本文为准；交互契约以 04 为准。** 两者冲突时，04 的"本地页 / Web 页两个面"是产品决策，本文只回答 iOS 能不能、代价是什么。

---

## 0. 结论先行

1. **服务工作区 HTML，选自定义 scheme（`pdsh-page://`），不选本地 HTTP，也不选 `loadFileURL`。** 自定义 scheme 在 iOS 26.5 上是 **secure context**，`fetch` / ES module / `localStorage` 全部可用，且**没有监听端口、没有跨 app 攻击面、没有端口生命周期**。**[实测]**
2. **`loadFileURL(_:allowingReadAccessTo:)` 不能承载现代页面**：`fetch('asset.json')` 直接 `TypeError: Load failed`，ES module 被 CORS 拒（`Cross-origin script load denied`）。它只适合"单文件、全内联、无模块、无 fetch"的老式 HTML。**[实测]**
3. **`loadHTMLString(_:baseURL:)` 只能用于可信的静态片段**：`origin` 为 `null`、`isSecureContext=false`、`localStorage` 抛 `SecurityError`、`crypto.subtle` 不存在、`fetch` 报 "URL is not valid"。仓库里旧的 `about:blank` HTML 预览就是死在这条路上（`spec/v1/render-media-v1.md` §0 第 2 条已记录）。**[实测]**
4. **WKWebView 没有 Service Worker。** `'serviceWorker' in navigator === false`，在自定义 scheme、`file://`、`http://127.0.0.1`、`localhost`、持久/非持久 `WKWebsiteDataStore` 六种组合下**全部为 false**。所以"用 localhost 就能跑 PWA/离线缓存"是错的；任何依赖 SW 的页面都要准备降级提示。**[实测]**
5. **`http://127.0.0.1:<port>` 与 `http://localhost:<port>` 在 WKWebView 里可直接加载，且是 secure context**（`crypto.subtle` 可用），**本次实测不写任何 ATS 键也能加载**。但 `127.0.0.1` 在**真机上是手机自己**，不是你的 Mac；模拟器才等于 Mac 的 loopback。**[实测] + [推断]**
6. **WKWebView 自己发起的流量不需要本地网络权限**（TN3179 明确豁免 WKWebView / SFSafariViewController / Safari），loopback 又不属于"local network"，所以"预览用户给的 `http://localhost:<port>`"**不需要** `NSLocalNetworkUsageDescription`、不需要 Bonjour、不需要 multicast entitlement。只有 App 自己用 `NWBrowser` / `URLSession` 去发现/探测局域网时才需要。**[文档]**
7. **不要用 `NSAllowsArbitraryLoads` 或 `NSAllowsArbitraryLoadsInWebContent`**：前者过宽，后者上架要写理由。保留现有 `NSAllowsLocalNetworking` + `127.0.0.1` / `localhost` 例外，补一个 `::1` 即可。**[文档]**
8. **Office（doc/docx/xls/xlsx/ppt/pptx）只有 Quick Look 一条原生路**，且 **QL 只能整屏 modal/push，不能内联成卡片**（Apple 只对 Mac Catalyst 明确说内联只显示缩略图；iOS 没有内联承诺，仓库现有 `EmbeddedQuickLook` 属于实践用法、未验收）。表格的"内联可读"要用 CSV/TSV 原生网格，或做 xlsx 解析（第三方），不要指望 QL。**[文档] + [SDK]**
9. **PDF 用 PDFKit `PDFView` 内联，视频/音频用 AVKit 内联，图片用 ImageIO 降采样 + `UIImageView`，Live Photo 用 `PHLivePhotoView`，USDZ 用 Quick Look（含 AR），glb/gltf 用自定义 scheme + three.js。** Quick Look 只做兜底和"打开方式…"，不做主力内联渲染器。**[SDK]**
10. **默认不给 JS 桥。** 需要桥时用 `WKScriptMessageHandlerWithReply` + `WKContentWorld` + `frameInfo.isMainFrame` + `securityOrigin` 白名单，且只挂到"预览页面"的 world；现有 `pdsh-page:` 的设计（无 message handler、CSP 由宿主注入）应保持。**[SDK] + 仓库现状**
11. **用户提供的 localhost 服务应是一个独立的"浏览器面"，不是文件预览器的一个渲染分支。** 它有自己的 `WKWebsiteDataStore`、自己的导航白名单（只允许用户输入的那个 origin）、自己的 JS 开关；**绝不**与 `pdsh-page://` 混在同一个 WKWebView 里。**[推断，与 04 §4.7 一致]**
12. **一句话推荐**：`pdsh-page://<session>/<path>` + 宿主注入三档 CSP + 无桥 + `nonPersistent` store + GET/Range 流式 + 原生渲染器分流；localhost 只作为"显式用户动作"打开的独立 Web 面；Office 整屏 QL；失败一律落到"为什么 + 还能做什么"。

---

## 1. WKWebView 六种加载路径：实测矩阵（iOS 26.5 模拟器）

同一段探针 JS 在六个 origin 上跑同一组能力检测。结果如下（原始 JSON 见附录 A）。

| 能力 | 自定义 scheme `probe://test` | `loadFileURL`（目录授权） | `loadHTMLString(baseURL:nil)` | `http://127.0.0.1:8791` | `http://localhost:8791` | 远程 `https://`（未测） |
|---|---|---|---|---|---|---|
| `location.origin` | `probe://test` | `file://` | `null` | `http://127.0.0.1:8791` | `http://localhost:8791` | 真实 origin |
| `isSecureContext` | **true** | **true** | **false** | **true** | **true** | true（HTTPS） |
| `crypto.subtle` | 有 | 有 | **无** | 有 | 有 | 有 |
| `localStorage` | 可读写 | 可读写 | **`SecurityError: The operation is insecure.`** | 可读写 | 可读写 | 可读写 |
| `document.cookie` | **写入后读回为空** | 可读写 | 空 | 可读写 | 可读写 | 可读写 |
| 同源 `fetch('asset.json')` | **200** | **`TypeError: Load failed`** | **`TypeError: URL is not valid...`** | 200 | 200 | 取决于 CORS |
| 同源 ES module `import('./mod.js')` | **`module-ok`** | **`Cross-origin script load denied...`** | **`Module name ... does not resolve to a valid URL`** | `module-ok` | `module-ok` | 取决于 CORS |
| 跨源 `fetch`（带 `ACAO:*`） | **200** | 失败 | 失败 | n/a | n/a | 视服务器 |
| 跨源 `fetch`（无 `ACAO`） | **`TypeError: Load failed`** | 失败 | 失败 | n/a | n/a | 被 CORS 拒 |
| 跨源 module（带 `ACAO:*`） | `cors-module-ok` | 失败 | 失败 | n/a | n/a | 视服务器 |
| 跨源 module（无 `ACAO`） | `nocors-module-ok`（本 build 未拒，见 §2.5） | 失败 | 失败 | n/a | n/a | 被 CORS 拒 |
| `navigator.serviceWorker` | **不存在** | **不存在** | **不存在** | **不存在** | **不存在** | **不存在** |
| Range / `<video>` seek | 取决于 handler（仓库已实现 206） | 系统文件读；`<video>` 未验证 | 无 | 服务器决定 | 服务器决定 | 服务器决定 |
| ATS | 不经过 ATS | 不经过 ATS | 不经过 ATS | **不写 ATS 键也能加载** | 同上 | 需合规 TLS |

补充实测：

- **自定义 scheme 页 fetch `http://127.0.0.1:8792`（服务器回 `ACAO:*`）→ 200**，**没有**被 mixed content 拦。反过来说：**自定义 scheme 页面不是"https 级"的 mixed-content 源**，它能不能访问 loopback 只看 CORS。**[实测]**
- 同一请求打到 8791（Python 默认服务器，无 `ACAO`）→ `TypeError: Load failed`。**失败原因是 CORS，不是 mixed content**。**[实测]**
- **持久 store 不改变 Service Worker 的可用性**：`.default()` 与 `.nonPersistent()` 结果相同，`navigator.serviceWorker` 都不存在。**[实测]**
- `loadFileURL` 下 `document.cookie` **可以**读写（`file://` 共享 cookie 存储），但 `fetch` 和 module 不通 —— 这条组合拳决定了它不能做现代页面容器。**[实测]**

### 1.1 与仓库里 macOS 旧探针的冲突（要说清楚）

`$TMPDIR/pdsh-probes/probe-report.json`（2026-10-30，macOS 26.3.1）记录：`http://127.0.0.1` 与 `http://localhost` 的 `isSecureContext` 都是 **false**，`crossOriginIsolated=false`。本次 iOS 26.5 模拟器量到的是 **true**。两者不矛盾，是平台/构建差异：

- 那条记录属于 **macOS 系统 WKWebView**，且明确标了 `NOT_VERIFIED on an iPhone`；
- 本文的矩阵是 **iOS 26.5 模拟器**，是本项目真正的目标平台。

**结论：不要拿 macOS 探针的 secure-context 结论去推 iOS。** 反过来，真机（尤其带 Lockdown Mode / 企业配置）仍应复测一次，见附录 B。

### 1.2 这些数字对预览器的直接含义

| 结论 | 影响的决策 |
|---|---|
| 自定义 scheme 有 origin、有 secure context、有 storage、有 module/fetch | 可以放心把工作区 HTML 跑在 `pdsh-page://`；WebGL/three.js、`importmap`、动态 `import()` 都成立 |
| 自定义 scheme 没有 cookie | 页面若依赖 cookie 登录态，必须走 localhost 面；预览页不要承诺 cookie |
| file URL 没有 fetch/module | `loadFileURL` 只能当"单文件 legacy HTML / 离线快照"降级路径 |
| htmlString 没有 origin | 只用于 **可信** 的静态片段（如 sanitize 后的 Markdown 内联 HTML），永不用于工作区 `.html` |
| loopback 是 secure context，但没 SW | localhost 面可以跑现代 JS、`crypto.subtle`、WASM；不能跑 PWA 离线缓存；要检测并提示 |
| 所有路径都没有 SW | 不要把 Service Worker 写进任何预览契约；官方 DSH Web 端如果在 phone 上跑，也要接受无 SW（`02-official-dsh.md` 的 host seam 不依赖 SW） |

---

## 2. WKWebView：API 级能力与约束

### 2.1 JS 开关：`javaScriptEnabled` 已废弃，用 `allowsContentJavaScript`

**[SDK]** `WKPreferences.h:115`：

```objc
@property (nonatomic) BOOL javaScriptEnabled
    API_DEPRECATED("Use WKWebpagePreferences.allowsContentJavaScript to disable content JavaScript on a per-navigation basis",
                   macos(10.10, 11.0), ios(8.0, 14.0));
```

**[SDK]** `WKWebpagePreferences.h:59-71`：

```objc
@property (nonatomic) BOOL allowsContentJavaScript API_AVAILABLE(macos(11.0), ios(14.0));
```

- 默认 `YES`；设为 `NO` 时页面里的 `<script>`、外链 JS、`javascript:` URL 全部不执行，但 **App 仍可通过 `evaluateJavaScript` / `callAsyncJavaScript` / `WKUserScript` 执行**（头文件原文）。这意味着"关 JS"不是安全边界，只是"不执行页面自带脚本"。
- 每导航可覆盖：`webView(_:decidePolicyFor:preferences:decisionHandler:)`（iOS 13+）里改 `preferences.allowsContentJavaScript`，再返回 `.allow`。这正好支撑"按文件/按会话的 JS opt-in"。
- 仓库现状 `Sources/PhoneDSHEngine/WebEngine.swift:186-187` 同时设了废弃的 `preferences.javaScriptEnabled = true` 和新的 `allowsContentJavaScript = true`；`PageSurface.swift:123` 只设了新的。**建议删掉 `javaScriptEnabled` 行**，避免以后误以为它还有语义。
- `PageSurface.swift:130-133` 注入的 `WKUserScript`（错误条）在关 JS 时仍会跑 —— 这是设计内的，没错。

**JS opt-in 建议**：

| 内容 | 默认 | 理由 |
|---|---|---|
| 工作区 `.html`（PAGE 面） | **开**（产品设置里可关，UI 有 `脚本开/关` chip） | 04 §4.7 已定；关掉后 three.js/交互全废 |
| 工作区 `.svg` | **关** | SVG 可含 `<script>`；预览只需要静态图，用 `UIImage`/`WKWebView` 关 JS 均可 |
| Markdown 内联 HTML | **关**（并 sanitize） | 不需要脚本 |
| 用户 localhost 服务 | **开**（它就是网页） | 但必须隔离数据存储与导航 |
| Office/PDF/图片/音视频 | 不经过 WebView | — |

### 2.2 `WKURLSchemeHandler`：契约、注册规则、坑

**[SDK]** `WKWebViewConfiguration.h:215-227`（原文要点）：

- 每个 scheme 只能注册一个 handler；**重复注册抛异常**；
- scheme 大小写不敏感，必须以 ASCII 字母开头，只允许字母/数字/`+`/`-`/`.`；
- **给 WebKit 内建 scheme 注册会抛异常**；用 `+[WKWebView handlesURLScheme:]` 预检；
- 必须在**创建 WKWebView 之前**设置到 configuration 上，事后设置无效。

**[SDK]** `WKURLSchemeTask.h` 原文要点：

- `didReceiveResponse:` 每个 task **至少调用一次**；**跨源请求需要 CORS 头**；
- 先 response 后 data；`didFinish` 前必须有 response；
- **`stopURLSchemeTask` 之后任何回调都会抛异常** —— handler 必须自己记录 stopped 集合并丢弃迟到的投递。仓库 `PageSchemeHandler.swift:316-374` 已经用 `stopped: Set<ObjectIdentifier>` + `deliverIfRunning` 做了这件事，是本仓库最值得保留的实现之一；
- 协议整体是 `WK_SWIFT_UI_ACTOR`（主线程），文件 IO 必须自己挪到后台队列（仓库用 `DispatchQueue(label: "dev.phone-dsh.page-scheme")`，`PageSchemeHandler.swift:309-310`）。

**自定义 scheme 的请求特征 [实测]**：

- 页面 URL 就是 origin 本身：`probe://test/index.html` 的 `location.origin === "probe://test"`；相对路径、绝对路径、`import('./mod.js')` 都能解析；
- **host 是 origin 的一部分**：`probe://lib/...` 与 `probe://test/...` 是**跨源**。跨源 `fetch` 必须回 `Access-Control-Allow-Origin`；没回就是 `TypeError: Load failed`；
- 自定义 scheme 下 `document.cookie` 写入不生效（读回空串），但 `localStorage` 正常；
- `isSecureContext === true`，`crypto.subtle` 存在；
- **没有** `navigator.serviceWorker`。

**一个本 build 的怪行为 [实测]**：跨源 **module** 在不带 `ACAO` 时也 import 成功了（`nocors-module-ok`），而跨源 **fetch** 不带 `ACAO` 就失败。这与仓库注释里"模块脚本是 CORS 请求、没有 ACAO 会报 Cross-origin script load denied"（`PageSchemeHandler.swift:442-447`、`Tests/PhoneDSHEngineTests/PageSchemeHandlerTests.swift:246-248`）不一致。**不要依赖这个宽松行为**：仓库继续发 `ACAO` 是对的；测试里那条注释应改成"fetch 需要 CORS；module 在本 build 未强制，但按规范仍应带"。

**建议的 CORS 收紧**：现在 `PageSchemeHandler.swift:446` 对所有响应发 `Access-Control-Allow-Origin: *`。因为 `*` 意味着"任何 origin 都能读"，而 `pdsh-page://` 里的页面又确实能跨会话读（spec 的有意决策），更稳的做法是：

```swift
// 只有当请求的 Origin 是 pdsh-page://<已知 session> 或 pdsh-page://lib 时回显
if let origin = task.request.value(forHTTPHeaderField: "Origin"),
   origin.hasPrefix("pdsh-page://") { headers["Access-Control-Allow-Origin"] = origin }
```

`Cross-Origin-Resource-Policy: cross-origin` 保留（跨 host 需要）。

### 2.3 三种加载 API 的语义边界

| API | 语义 | 页面 origin | 能做什么 | 不能做什么 |
|---|---|---|---|---|
| `load(_ request:)` / `load(URLRequest)` | 通用导航 | 由 URL 决定 | 自定义 scheme、http(s) | — |
| `loadFileURL(_:allowingReadAccessTo:)`（iOS 9+，**[SDK]** `WKWebView.h:132`） | 从文件加载，`readAccessURL` 是**目录或单文件**，必须 file URL | `file://` | 单文件 HTML、内联脚本、图片、CSS、`localStorage`、cookie | **`fetch`、ES module、`<video>` 之外的子资源跨目录读**（实测 fetch/module 失败） |
| `loadHTMLString(_:baseURL:)`（**[SDK]** `WKWebView.h:139`） | 加载字符串，`baseURL` 可为 nil | `null`（baseURL 为 nil 时） | 可信静态片段、富文本、打印 | storage、`crypto.subtle`、fetch、module、相对资源 |
| `loadFileRequest(_:allowingReadAccessTo:)`（iOS 15+） | 同 `loadFileURL`，但保留请求头/attribution | `file://` | 同上 | 同上 |
| `loadSimulatedRequest(_:response:responseData:)`（iOS 15+） | 给一个 URL 造一个假响应 | 请求 URL 的 origin | 单测/离线回放 | 不是生产加载路径 |

**关键约束（[SDK] 头文件原文）**：`loadFileURL` 的 `readAccessURL` 是"授权目录"，WebKit 只能读这个目录下的内容；传单文件 URL 就只读那一个文件。**它不会给页面一个 http 式 origin**，所以 `fetch`/module 的失败是设计结果，不是 bug。

### 2.4 `loadRequest` + 内嵌 loopback HTTP：能力与代价

如果自己起一个 `NWListener`（仓库已有 `Sources/PhoneDSHLoopback/LoopbackServer.swift`，Network.framework，127.0.0.1 临时端口），把工作区目录当静态站点伺服，WKWebView 加载 `http://127.0.0.1:<port>/index.html`：

**得到**：真实 http origin、cookie、`Secure` 以外的完整 cookie 语义、`fetch`/module 正常、`crypto.subtle`、`navigator.clipboard` 等 secure-context API 与 HTTP 源一致、媒体 Range 自然支持、和官方 DSH Web 端"必须有 http(s) origin"的假设一致（`02-official-dsh.md` §4.3 第 1 条）。

**付出**：

1. **多一个监听 socket**：iOS 上 **127.0.0.1 是所有 App 共享的**，任何本机 App 都能连（和 Android 一样；`docs/design/security-checklist-2026-10-31.md` §1 的结论在 iOS 同样成立）。所以必须带 per-launch token，且所有路由都要鉴权；token 不能进 URL query（会进 referer/日志）。
2. **端口生命周期**：bind/释放、端口冲突、后台挂起时 listener 行为、`park/resume` 后 origin 变化导致 `localStorage`/cookie 丢失。仓库 `WebHostConfiguration.swift:129-136` 已经为"固定端口"付过一次复杂度代价。
3. **路径校验要重写一遍**：静态文件路由同样要逐段校验 + realpath + 前缀，和 scheme handler 是两套代码、两套测试。
4. **CSP 注入、MIME、Range、416、HEAD** 都要在 HTTP 层再做一遍。
5. **跨 app 面**：别的 App 可以探测端口、发请求；即使读不到（CORS/token），也多了 CSRF/端口扫描面。
6. **仍然没有 Service Worker**（实测）。所以"为了 SW 才上 localhost"是无效动机。

**结论**：**只有两种情况值得上内嵌 HTTP**：(a) 必须跑官方 DSH Web 客户端（它按 `http(s)` 拼 `fileMediaUrl()`，自定义 scheme 会静默降级，见 `02-official-dsh.md` §4.3）；(b) 预览目标本身就是一个需要 cookie/真实 origin 的本地服务。**纯工作区 HTML 预览不值得。**

### 2.5 ES modules / fetch / localStorage / service worker / CORS 一页总结

| 主题 | 事实 | 依据 |
|---|---|---|
| ES module | 自定义 scheme 同源可用；跨源需 CORS（本 build module 未强制，fetch 强制） | [实测] |
| `fetch` | 自定义 scheme 同源/跨源（带 ACAO）都可用；file:// 不可用；about:blank 不可用 | [实测] |
| `localStorage` | 自定义 scheme / file:// / loopback / localhost 都可用；about:blank 抛 `SecurityError` | [实测] |
| cookie | 自定义 scheme 写不进；file:// 与 http 可用 | [实测] |
| Service Worker | **WKWebView 全路径不可用**（`navigator.serviceWorker` 不存在） | [实测] |
| CORS | 方案：scheme handler 回 `ACAO`；跨源 `fetch` 无 ACAO 直接失败 | [实测] + [SDK] |
| 混合内容 | 自定义 scheme 页（secure context）fetch `http://127.0.0.1`，带 CORS 时 **200**，未被拦 | [实测] |
| 同源判定 | 自定义 scheme 的 host 参与 origin；`pdsh-page://lib` 与 `pdsh-page://<session>` 是跨源 | [实测] |

### 2.6 ATS 与本地网络：精确规则

**ATS（[文档] Apple `NSAllowsLocalNetworking` / `NSExceptionDomains` / `NSAppTransportSecurity`）**：

- ATS 默认要求 HTTPS；用 `NSAppTransportSecurity` 放宽；
- `NSAllowsLocalNetworking`（iOS 10+）允许 **unqualified domain、`.local`、IPv4/IPv6 地址**；
- **iOS 17+：ATS 默认不再放行 IP 字面量**，要在 `NSExceptionDomains` 里逐个写 IP 或 CIDR（`NSExceptionDomains` 文档：iOS 17 起 key 可以是 `192.168.42.63` 或 `2001:db8:12::/48`）；
- `NSExceptionDomains` 的 key **不能带端口**，不能通配，域名与 IP 不互相套用；
- `NSAllowsArbitraryLoadsInWebContent` 只豁免 WKWebView，但**上架要写理由**；`NSAllowsArbitraryLoads` 更宽，别用。

**本次实测（重要）**：**Info.plist 完全不写 ATS 键，WKWebView 仍能加载 `http://127.0.0.1:8791` 与 `http://localhost:8791`。** 说明 loopback 在 WKWebView 里不触发 ATS 拦截（Apple 的 IP 收紧主要打到真实局域网 IP）。但：

- **原生 `URLSession` 访问 IP 字面量是另一回事**（`Preventing Insecure Network Connections` 明确 ATS 只管 URL Loading System，且 iOS 17+ IP 默认不放行）——如果 App 自己用 URLSession 探 loopback，就需要例外；
- **用户输入的局域网 IP**（`http://192.168.1.5:3000`）是第三种情况，需要 `NSAllowsLocalNetworking` 或显式 IP 例外，而且会触发本地网络权限（见下）。

**本地网络隐私（[文档] TN3179）**：

- "local network" = 与**广播型接口**（Wi-Fi/Ethernet，不含蜂窝/VPN）关联的 IP 网络；loopback **不是** local network；
- **`WKWebView`、`SFSafariViewController`、Safari 发起的流量不需要本地网络权限**（TN3179 原文例外条款）；
- 需要权限的是 App 自己：`URLSession` 连局域网、`NWBrowser`/Bonjour 浏览/注册/解析、UDP 组播/广播（后者还要 `com.apple.developer.networking.multicast`）；
- 首次触发弹窗；**模拟器不实现本地网络隐私**，必须真机测；
- 后台且未决时会直接拒绝且不记录。

**这意味着**：只要预览的网页加载全部发生在 WKWebView 内，**"预览用户给的 `http://localhost:<port>`"不需要任何权限声明**；只有"帮用户发现局域网里的服务"才需要 `NSLocalNetworkUsageDescription` + `NSBonjourServices`。现有 `Info.plist` 已经声明了 `_pdsh._tcp.` 和 `NSLocalNetworkUsageDescription`（给 MCP 用），**不要**为了 localhost 预览再加 Bonjour 类型。

### 2.7 其他值得用的开关（都在 SDK 里核对过）

| API | 可用性 | 用途 / 注意 |
|---|---|---|
| `WKWebView.isInspectable` | iOS 16.4+，默认 `false` | release 保持 `false`；仓库 `PageSurface.swift:137` 已是 false |
| `WKWebpagePreferences.isLockdownModeEnabled` | iOS 16+ | 用户开了 Lockdown 就为 true；按 spec B.9 强制 `sandbox` 档、禁 `online` |
| `WKWebpagePreferences.securityRestrictionMode` | **iOS 26.5 新增** | `.maximizeCompatibility` 关 JIT + 扩 MTE，专给"高风险内容"；会显著拖慢 WebGL。默认 `.none`；预览不可信页面可考虑 |
| `WKSecurityRestrictionMode`（`WKWebpagePreferences.h:104-121`） | iOS 26.5 | `.none` / `.maximizeCompatibility` / `.lockdown`；系统 Lockdown 时降级会静默失败 |
| `allowsInlineMediaPlayback` | iOS 10+ | HTML 里的 `<video>` 内联播放（仓库已设 `PageSurface.swift:125`） |
| `mediaTypesRequiringUserActionForPlayback` | iOS 10+ | 设 `[]` 让自动播放可行；预览页要谨慎（别自动出声） |
| `allowsPictureInPictureMediaPlayback` | iOS 9+ | 视频画中画 |
| `limitsNavigationsToAppBoundDomains` | iOS 14+ | 需要 `WKAppBoundDomains` Info.plist；会锁死只允许列出的域。**预览不适用**（用户端口/主机不可预知） |
| `upgradeKnownHostsToHTTPS` | iOS 14.5+ | 对 localhost 预览**必须保持 false**（默认 false），否则已知主机可能被升 https 打不开 |
| `preferredHTTPSNavigationPolicy` | iOS 18.2+ | 同上，默认 `KeepAsRequested`；不要设 auto-upgrade |
| `pageZoom` / `find(_:configuration:)` | iOS 14+ | 页面缩放/查找；官方 DSH 的 HTML 预览明确不做 zoom（`02-official-dsh.md` §5.7），iOS 可给 |
| `createPDF(configuration:)` / `takeSnapshot(configuration:)` | iOS 14+ / 11+ | 生成缩略图、导出；注意 snapshot 不等于渲染成功 |
| `WKContentRuleListStore` | iOS 11+ | 额外的网络 kill-switch（见 §6.4） |

---

## 3. 服务工作区 HTML：三方案决策矩阵

问题定义：用户/Worker 在 workspace 里写了一个 `index.html`，同目录有 `.js`、`.css`、贴图、`.glb`；要"像网页一样跑"（spec §B.1），并且默认不出网。

### 3.1 矩阵

| 维度 | **A. 自定义 scheme `pdsh-page://`**（推荐） | **B. 内嵌 loopback HTTP** | **C. `loadFileURL` 目录授权** | **D. `loadHTMLString`** |
|---|---|---|---|---|
| origin | `pdsh-page://<session>`（真实、可分 session） | `http://127.0.0.1:<port>`（真实） | `file://` | `null` |
| 相对资源 | 可用 | 可用 | 可用 | 不可用（无 base） |
| ES module | 可用 [实测] | 可用 | **不可用** [实测] | **不可用** [实测] |
| `fetch` | 可用（同源/带 CORS 跨源）[实测] | 可用 | **不可用** [实测] | **不可用** [实测] |
| `localStorage` | 可用（按 scheme+host 隔离） | 可用 | 可用 | **SecurityError** |
| cookie | **不可用** [实测] | 可用 | 可用 | 不可用 |
| Service Worker | 无 | 无 | 无 | 无 |
| Range / 大 `.glb` | handler 自己实现（仓库已做 206 + 1 MiB 分块） | 服务器实现 | 支持（系统） | 不支持 |
| CSP 注入 | handler 回 response header（页面不能放宽） | HTTP 头 | 只能 `<meta>`（页面可改） | 只能 `<meta>`（页面可改） |
| 端口/监听面 | **无** | 有（全机 App 可连） | 无 | 无 |
| 生命周期/清理 | WebView 释放即结束；无端口 | bind/释放、park/resume、端口冲突 | 无 | 无 |
| 跨 app 暴露 | 无 | 有（token 才挡住） | 无 | 无 |
| ATS/本地网络 | 不涉及 | loopback 不涉及（实测） | 不涉及 | 不涉及 |
| 实现量 | 中（仓库已有 508 行 + 测试） | 大（静态路由/鉴权/端口/CSP/MIME 全再来一遍） | 小 | 极小 |
| 适合 | **工作区 HTML / 3D** | 官方 Web 客户端、需要 cookie 的本地服务 | 单文件 legacy HTML 降级 | 可信静态片段 |

### 3.2 方案 A（推荐）的落地细节

仓库已有实现，直接复用并小改：

- URL 形状：`pdsh-page://<sessionID>/<relative-path>`，`pdsh-page://lib/<asset>` 保留给内置 Web3DLib（`PageSchemeHandler.swift:196-200`）。`lib` 是保留 host；
- 校验：逐段拒绝 `.`、`..`、`\`、NUL，`removingPercentEncoding` 后再拆；拼完 `resolvingSymlinksInPath`，再与 root 前缀比较（`PageSchemeHandler.swift:104-117`、`:83-89`）。跨会话读是 spec 的有意设计，但"跨会话 ≠ 跨根"；
- 只允许 `GET`（可带一个 `Range`）；非 GET 回 405；Range 非法回 416 + `Content-Range: bytes */total`；`Cache-Control: no-store`（`:385-427`）；
- MIME 表：`PageSchemeHandler.swift:203-225`；未知扩展名 `application/octet-stream`。**建议补** `.avif`（`image/avif`）、`.wasm` 已有、`.mp3/.m4a/.wav`（音频预览）、`.usdz`（`model/vnd.usdz+zip`）；
- 流式：响应头前先打开文件/读首块，避免"200 头 + 空 body"（`:402-436`）；1 MiB 一块（`:378`）；
- CSP：页面用 `<meta name="pdsh-csp" content="sandbox|local|online">` 声明档位，**header 由宿主生成**（`:227-266`、`:454-458`）。三档见 §6.3；
- CORS：至少保留 `ACAO`（跨 host 的 module/fetch 需要）；建议从 `*` 收紧为回显 `pdsh-page://` origin（§2.2）；
- 清理：`setURLSchemeHandler(nil, forURLScheme:)` 不是必须；释放 WKWebView + `nonPersistent` store 即回收。没有端口要释放，这是它相对 B 的最大优势。

**失败语义**：`didFailProvisionalNavigation` / `didFail` → 原生错误页；`webViewWebContentProcessDidTerminate` → 重建 WebView 并恢复 URL（页面状态丢失，给出"已重新加载"提示）；页面内 `window.onerror` / `unhandledrejection` → 底部错误条（`PageSurface.swift:149-176` 已有）。**不要**把 handler 的 404 伪装成空白页——`didFailWithError` 带 `NSURLErrorFileDoesNotExist` 更好定位。

### 3.3 方案 B 的适用条件（如果将来要跑官方 Web 客户端）

- 只在"完整 DSH Web 端"或"用户明确要 cookie/真实 http origin"时启用；
- 复用 `PhoneDSHLoopback`：token 走 `Authorization` 或 HttpOnly cookie，**不进 URL query**（现状 `WebEngineConfiguration.makePageURL` 把 token 放 query，是既有 D2 决策，预览场景不要复制）；
- 静态路由必须复用 A 的 resolver（`PDSHPageResolver`）而不是新写一套；Range/416/MIME 与 A 同一份代码；
- bind 失败/端口被占：回退到临时端口并接受 origin 变化（localStorage 丢失），或直接失败并提示；
- 后台：listener 随 App 挂起停止，恢复时重新 bind；预览页在后台没有意义，可不做保活；
- 安全：所有路由鉴权；不允许目录列表；不允许 `..`；CSP 头由服务器注入。

### 3.4 方案 C 的边界

只用于：单文件 HTML（脚本内联、无外链 module/fetch）、导出/归档快照、以及"HTML 超过 8 MiB 不内联"的兜底（spec B.9）。**不要**把它当作工作区 HTML 的主路径——实测 fetch/module 都失败。

### 3.5 方案 D 的边界

只用于**可信**片段：sanitize 后的 Markdown 内联 HTML、邮件式富文本、错误页。永不用于工作区 `.html`（现状 `FilesPage.swift` 的 `IsolatedHTMLPreview` 属于这一类，`01-current-ios.md` 已把它列为待替换）。

---

## 4. 用户提供的 `http://localhost:<port>` 服务

### 4.1 能不能直接预览

**能。** WKWebView 直接 `load(URLRequest(url:))` 一个 `http://127.0.0.1:<port>` / `http://localhost:<port>` 即可，页面按普通网页运行；实测：

- `isSecureContext = true`、`crypto.subtle` 可用、`localStorage`/cookie 可用、同源 `fetch`/module 可用；**[实测]**
- 不写任何 ATS 键也能加载；**[实测]**
- 不需要本地网络权限、不需要 Bonjour；**[文档 TN3179]**
- **没有 Service Worker**，PWA 的离线/推送/后台同步不可用；**[实测]**
- 它的 `Origin` 就是 `http://127.0.0.1:<port>`，与 App 自己的 loopback 是**不同端口 = 不同 origin**；cookie/storage 不共享（但同机 App 都能访问该端口）。

**不能**：

- 不能把 localhost 页面塞进 `pdsh-page://` 页面里当 iframe 还指望它"同源"——它是跨源，`fetch` 需要 CORS，`X-Frame-Options`/CSP `frame-ancestors` 也可能拒绝；
- 不能替它注册 Service Worker（WKWebView 没有）；
- 不能读它的响应体（跨源 + 无 CORS），只能显示；
- 不能保证它一定在跑——必须有超时与"服务未启动"的明确错误。

### 4.2 ATS / Info.plist 精确写法

现有 `examples/probe-app/Config/PhoneDSHProbe-Info.plist:141-158` 已经是正确方向：

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>
  <key>NSExceptionDomains</key>
  <dict>
    <key>127.0.0.1</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    <key>localhost</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    <!-- 建议补 IPv6 loopback；iOS 17+ 的 NSExceptionDomains 支持 IPv6 字面量 -->
    <key>::1</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
  </dict>
</dict>
```

要点：

- **不要**加 `NSAllowsArbitraryLoads`（全 App 放开）或 `NSAllowsArbitraryLoadsInWebContent`（上架要理由）；
- 例外 key **不带端口**；`127.0.0.1` 的例外覆盖所有端口；
- 如果要支持用户输入**局域网 IP**，`NSAllowsLocalNetworking` 已覆盖 IP 地址，但 iOS 17+ 对 IP 的默认收紧仍需实测；必要时加具体 IP/CIDR 例外（不能通配）；
- 如果 App 自己用 `URLSession` 探 loopback，同样受 ATS 约束（URL Loading System），需要上述例外。**注意**：这不等于"WKWebView 豁免 ATS"——ATS 仍适用于 WebView 的非 loopback 明文加载（`NSAllowsArbitraryLoadsInWebContent` 就是为此存在）；本次只是实测 loopback 不触发它。

### 4.3 本地网络权限 / Bonjour / mDNS

| 场景 | 需要什么 | 说明 |
|---|---|---|
| WKWebView 加载 `http://localhost:<port>` | **什么都不用** | loopback 不是 local network；WKWebView 流量还被 TN3179 豁免 |
| WKWebView 加载 `http://192.168.x.x:<port>` | 无（WKWebView 豁免），但 ATS 例外可能要 | 仍是"用户显式输入 + 显式确认"的产品决策 |
| App 用 `URLSession` 探测局域网 | `NSLocalNetworkUsageDescription` + 用户授权 | 首次触发系统弹窗；后台未决会被静默拒绝 |
| App 用 `NWBrowser`/Bonjour 发现服务 | 上面 + `NSBonjourServices`（具体 `_type._tcp`） | 不能浏览任意类型；`_services._dns-sd._udp` 还要 multicast entitlement |
| UDP 组播/广播 | `com.apple.developer.networking.multicast` | 预览不需要 |

**避免过度授权的做法**：

1. 默认只允许 **loopback**（`127.0.0.1` / `localhost` / `::1`），不做 mDNS 发现；
2. 局域网地址作为**显式动作**（用户粘贴/确认），不要在工作区 HTML 里自动探测；
3. `NSLocalNetworkUsageDescription` 的文案只描述已存在的 MCP 场景，不要为 localhost 预览加新理由；
4. 不申请 multicast entitlement；
5. 模拟器不实现本地网络隐私，**权限相关行为必须真机验收**。

### 4.4 模拟器 vs 真机（最容易踩的坑）

| | 模拟器 | 真机 |
|---|---|---|
| `127.0.0.1` 指向 | **Mac 主机**（共享网络栈） | **iPhone 自己** |
| 能预览 Mac 上的 dev server | 能 | **不能**（除非用 Mac 的局域网 IP，且走本地网络权限/ATS） |
| 本地网络权限 | 不实现（永远放行） | 真实弹窗 |
| 结论 | 只能验证"页面能跑"，不能验证权限/端口语义 | 必须在这里验收 |

**产品含义**：手机上的 "localhost 预览" 只有在**手机上真有一个服务**时才有意义（例如另一个 App 暴露的本地端口、或未来 App 内自带的 server）。不要把它宣传成"预览你电脑上的 dev server"；那是另一个功能（LAN 预览），权限与安全模型都不同。

### 4.5 localhost 面的安全模型（与文件预览完全隔离）

- **独立 WKWebView**，独立 `WKWebViewConfiguration`，独立 `WKWebsiteDataStore`：用 `WKWebsiteDataStore.dataStore(forIdentifier:)`（iOS 17+）为每个 localhost origin 建独立 store，关闭时 `removeDataStore(forIdentifier:)`；或直接 `.nonPersistent()`（关闭即清）。**[SDK]**
- **导航白名单**：只允许用户确认的 `scheme://host:port`（`decidePolicyFor navigationAction` 精确比较 `url.scheme/host/port`）；子资源不限制（同源即可），外链一律取消并提示；
- **不做 JS 桥**；如果将来要"从 localhost 页面触发 App 动作"，必须是显式、带用户手势、带 origin 校验的桥（见 §6.4）；
- **不注入 token**：localhost 页面永远拿不到 App 的 loopback token；
- **文件上传/下载/弹窗/媒体采集**全部显式拒绝（见 §6.5）；
- **提示条**：顶部显示 `本机服务 · 127.0.0.1:5173 · 非工作区内容`，让用户知道这不是 workspace 文件；
- **不自动加载**：工作区 HTML 里出现 `http://localhost:*` 链接时，只能作为"可点击的外部链接"，由用户点击后在 localhost 面打开，不能让页面自己导航过去（否则恶意 HTML 可借用户的 localhost 服务做 CSRF/端口探测）。

---

## 5. 原生渲染器：谁最适合渲染什么

### 5.1 PDF：PDFKit 内联，Quick Look 兜底

**[SDK] `PDFKit.framework`（iOS 11+）**：

| API | 用途 | 备注 |
|---|---|---|
| `PDFDocument(url:)` | 打开文件 | `isLocked` / `unlock(withPassword:)`；加密 PDF 要提示 |
| `PDFView.document` | 绑定 | `PDFView` 是 `UIView`，**可内联** |
| `PDFView.autoScales` | 适应宽度 | 默认 false；移动端一般 true |
| `PDFView.displayMode` | `.singlePageContinuous`（默认）/.singlePage/.twoUp… | 手机用 continuous 或 `usePageViewController` |
| `PDFView.usePageViewController(_:withViewOptions:)` | 翻页模式 | iOS 11+；`isUsingPageViewController` |
| `PDFView.pageShadowsEnabled` | 页阴影 | iOS 12+ |
| `PDFView.go(to:)` / `currentPage` | 跳页 | 配合缩略图 |
| `PDFThumbnailView` | 缩略图条 | 可选 |
| `PDFOutline` | 目录 | 可选 |
| `PDFDocument.findString(_:withOptions:)` | 搜索 | 返回 `[PDFSelection]`；大文档注意主线程 |
| `PDFPage.thumbnail(of:for:)` | 单页缩略图 | 列表/卡片用 |
| `PDFView.pageOverlayViewProvider` | 页上叠视图 | iOS 16+；批注/水印类 |

**建议**：PDF 用 `PDFView` 内联（D2 页面主体），自带滚动、缩放、选中、搜索；大文件（>100 MB / >1000 页）用 Quick Look 兜底或先给"打开方式…"。Quick Look 的 PDF 查看器更"系统"，但只能整屏。

### 5.2 图片：ImageIO + `UIImageView`，不要为预览申请相册权限

| 场景 | 做法 |
|---|---|
| PNG/JPEG/HEIC/AVIF/WebP/GIF | `CGImageSourceCreateWithURL` + `CGImageSourceCreateThumbnailAtIndex`，键：`kCGImageSourceCreateThumbnailFromImageAlways`、`kCGImageSourceThumbnailMaxPixelSize`、`kCGImageSourceCreateThumbnailWithTransform`、`kCGImageSourceShouldCacheImmediately`；按屏幕像素降采样，避免 4K 图爆内存 |
| 动图 GIF/WebP | `CGImageSourceGetCount` + 逐帧 `CGImage`，`UIImage.animatedImage(with:duration:)`；或 WKWebView 关 JS 显示 |
| Live Photo | `PHLivePhotoView`（PhotosUI，iOS 9.1+）+ `PHLivePhoto`；但预览任意文件时基本用不到，除非从相册导入 |
| 相册资产 | 用 `PHPickerViewController`（iOS 14+，**无需相册权限**，out-of-process）或 SwiftUI `PhotosPicker`（iOS 16+）；不要为预览申请 `NSPhotoLibraryUsageDescription` |
| SVG | 原生无渲染器；用 WKWebView **关 JS** 加载，或先用 `UIImage` 不支持则降级"分享/打开方式" |
| RAW/DNG | ImageIO 可解部分；失败就 Quick Look/分享 |
| 缩略图 | `QLThumbnailGenerator`（iOS 13+）可给 Office/PDF/未知类型出缩略图，用于列表卡片 |

### 5.3 视频/音频：AVKit 内联，Quick Look 只兜底

**[SDK] `AVKit.framework`**：

| API | 可用性 | 用途 |
|---|---|---|
| `AVPlayer(url:)` / `AVPlayerItem` | iOS 4+ | 本地文件直接播；`AVURLAsset` 读轨道/时长 |
| `AVPlayerViewController` | iOS 8+ | 内联（`addChild` + `didMove(toParent:)`）或全屏；`showsPlaybackControls`、`videoGravity`、`allowsPictureInPicturePlayback`（iOS 9+）、`canStartPictureInPictureAutomaticallyFromInline`（iOS 14.2+）、`entersFullScreenWhenPlaybackBegins`（iOS 11+） |
| `AVPlayerLayer` | iOS 4+ | 自定义控件/封面帧 |
| SwiftUI `VideoPlayer` | iOS 14+ | 最省事的内联播放器 |
| `AVAudioPlayer` / `AVAudioSession` | iOS 2+/6+ | 纯音频；`AVAudioSession.Category.playback` 支持后台/静音键 |
| `AVAssetImageGenerator` | iOS 4+ | 视频封面帧 |

**约束**：AVFoundation 只认系统支持的容器/编码（mp4/mov/m4v/H.264/HEVC/AV1 依设备）；`.mkv/.avi/.flv` 等不支持 → Quick Look（支持也有限）或分享。DRM/加密媒体不要碰。HLS `.m3u8` 是流媒体，本地文件预览不适用。

### 5.4 Office / 表格：Quick Look 唯一原生路，但有明确边界

**[文档] Apple Quick Look**：支持 iWork + Microsoft Office、图片、Live Photos、文本、PDF、音视频、USDZ。`QLPreviewController` 文档列的类型同上 + RTF + CSV。

**[SDK] `QuickLook.framework`**：

```swift
QLPreviewController()                       // iOS 4+
QLPreviewController.canPreview(item)        // 路由前先问
controller.dataSource = self                // QLPreviewControllerDataSource
controller.delegate = self                  // QLPreviewControllerDelegate
// 只读：不实现 editingModeFor，或显式返回 .disabled
```

**必须知道的限制**：

1. **只能整屏**：`QLPreviewController` 设计为 modal 或 push 进 `UINavigationController`。Apple 文档在 Mac Catalyst 一节明确："把 `QLPreviewController` 嵌进另一个 view controller 时，系统不显示实时预览，只显示缩略图"。iOS 上仓库现在用 `EmbeddedQuickLook` 子 VC（`FilesPage.swift:296-297`、`:456-487`）——它能跑，但属于**未支持用法**，Chrome/导航/编辑行为不保证。**建议改为从最顶层 VC 全屏 present**（`OfficePresenter.swift:90-135` 已经这么做），或至少把"内联 QL"标为实验路径。
2. **不能嵌套在 sheet 里再弹**：iOS 会静默拒绝嵌套 modal（`FilesPage.swift:452-454` 的注释就是踩过这个坑）。present 前先找到 top-most VC。
3. **保真度不保证**：Quick Look 是查看器，不是 Office。复杂图表、SmartArt、宏、条件格式、超大 sheet 可能缺失或截断；加密/密码保护的文档直接失败。
4. **不能自定义 chrome / 叠加视图**：Apple 原文——要在预览上叠视图、并排显示、加高级播放控制，用更低层 API。
5. **不能编辑**（对我们正好）：默认 `QLPreviewItemEditingMode.disabled`；不要实现 `didSaveEditedCopy`。
6. **一次一个 item 也行**：`numberOfPreviewItems` 可以 >1，QL 会给左右翻页；但预览器通常一次一个。
7. **数据源是 URL**：`QLPreviewItem.previewItemURL`；不能直接喂 `Data`（除非写临时文件，违反"只读、不落盘"）。工作区物化目录正好有文件 URL。
8. **USDZ**：QL 是唯一能一键进 AR 的入口（`ARQuickLookPreviewItem`）。

**表格的更好选择**：

- **CSV/TSV**：原生网格（`UICollectionView`/`UITableView` + 等宽数字），支持前 N 行虚拟滚动；不要用 QL（QL 的 CSV 只是文本）。
- **xlsx/xls**：原生无解析器。要么 QL 整屏，要么第三方解析（如 CoreXLSX）后自绘网格——后者工作量大、公式/样式/合并单元格都要自己处理，**P2 再做**。
- **numbers**：QL。
- **docx**：QL；若要内联，只能转 HTML/PDF（设备上没有 LibreOffice；官方 DSH 是 host 侧 LibreOffice 转 PDF，见 `02-official-dsh.md` §4.1），iOS 端不建议。

### 5.5 3D

| 格式 | 渲染器 | 说明 |
|---|---|---|
| `.usdz` | Quick Look（`ARQuickLookPreviewItem` / QL） | 系统唯一 AR 入口；全屏 |
| `.glb` / `.gltf` | `pdsh-page://` + three.js（`Web3DLib/`，spec B.5-B.6） | 需要 WebGL2；首帧预算 300 ms；`.glb` 走 Range 流式 |
| `.obj` / `.stl` | 可选 loader（P2） | 同上 |
| 其他 | 无 | 分享/打开方式 |

### 5.6 文本 / 代码 / Markdown / JSON / CSV

- 文本/代码：原生等宽 `UITextView`（或 SwiftUI `Text` + `ScrollView`），**从文件流式读**，不要再用 256 KiB/200 行内联（`01-current-ios.md` §4 已列为 P0）；
- Markdown：`NativeMarkdownBody`（现状）；
- JSON：格式化 + 折叠树；超大 JSON 只读前 N MB 并提示；
- CSV/TSV：网格；
- 二进制/未知：`QLPreviewController.canPreview` 问一下，能预览就 QL，不能就"分享/打开方式…"。

### 5.7 Quick Look 限制清单（汇总）

| 限制 | 影响 |
|---|---|
| 只能 modal/push，不能内联卡片 | D1 peek 不能放 QL；D2 也是整屏 |
| 不能嵌入后仍显示实时内容（Catalyst 文档明确；iOS 未支持） | 不要做"内联 QL" |
| 不能嵌套 modal | present 前找 top-most VC |
| 不能自定义工具栏/叠加视图 | 需要自定义就换原生框架 |
| 保真度受限 | Office 复杂文档要提示"以 Quick Look 显示，可能缺版式" |
| 密码/加密文档失败 | 明确错误 + 分享 |
| 只能 URL | 不能直接渲染内存数据 |
| 无 Service Worker/网络策略 | 它不加载网络（除了 iWork 的远程资源？不涉及） |
| 编辑能力 | 默认关闭；保持只读 |

### 5.8 渲染器总矩阵

| 文件类型 | 首选 | 内联? | 降级 | 关键 API |
|---|---|---|---|---|
| `.pdf` | PDFKit `PDFView` | 是 | QL 全屏 | `PDFDocument(url:)`、`PDFView.autoScales` |
| `.png/.jpg/.heic/.gif/.webp/.avif` | ImageIO + `UIImageView` | 是 | QL | `CGImageSourceCreateThumbnailAtIndex` |
| `.svg` | WKWebView（关 JS） | 是 | 分享 | `allowsContentJavaScript=false` |
| `.mp4/.mov/.m4v` | `AVPlayerViewController` | 是 | QL | `AVPlayer`、`allowsPictureInPicturePlayback` |
| `.mp3/.m4a/.wav` | `AVPlayer`/`AVAudioPlayer` | 是 | QL | `AVAudioSession` |
| `.doc/.docx/.ppt/.pptx/.xls/.xlsx/.pages/.numbers/.key` | Quick Look | **否（整屏）** | 分享/打开方式 | `QLPreviewController`、`canPreview` |
| `.csv/.tsv` | 原生网格 | 是 | QL（纯文本） | `UICollectionView` |
| `.txt/.md/.json/.yaml/.log/源码` | 原生文本 | 是 | 分享 | `UITextView`、流式读 |
| `.html/.htm` | `pdsh-page://` + WKWebView | 是 | 文本源码 | `PDSHPageView` |
| `.glb/.gltf` | three.js（`pdsh-page://`） | 是 | 分享 | WebGL2 + `GLTFLoader` |
| `.usdz` | Quick Look（AR） | 否 | 分享 | `ARQuickLookPreviewItem` |
| `.zip`/未知 | QL（能预览就预览） | 否 | 分享 | `canPreview` |
| `http(s)://` | 独立 Web 面（WKWebView） | 否（全屏浏览器面） | 系统浏览器 | `load(URLRequest)` |

---

## 6. 安全模型：把"能预览"限制在"只能预览"

### 6.1 原则

1. **预览页没有 App 能力**：不暴露任意文件系统、不暴露网络代理、不暴露 JS 桥；
2. **每个 origin 只做一件事**：`pdsh-page://` 只读工作区+bundle；localhost 面只连用户确认的那一个服务；
3. **读权限从根开始**：以物化工作区根为边界，逐段校验 + realpath + 前缀；
4. **默认不出网**：CSP 三档，`online` 必须显式；
5. **失败要说真话**：403/404/超时/格式不支持/加密，各有各的文案与出路。

### 6.2 scheme handler 路径穿越防护（逐条对照仓库）

| 攻击 | 防护 | 仓库位置 |
|---|---|---|
| `pdsh-page://S/../../etc/passwd` | 逐段拒绝 `..`、`.`、`\`、NUL，先解码再拆 | `PageSchemeHandler.swift:104-117` |
| 符号链接逃逸 | `resolvingSymlinksInPath()` 后与 root 前缀比较 | `:83-89` |
| 编码绕过（`%2e%2e`、`%5c`） | `removingPercentEncoding` 后再校验 | `:105-106` |
| 目录当文件读 | `fileExists(isDirectory:)` 拒绝 | `:90-94` |
| 未知 session | `workspaceRoot(host)` 返回 nil → `unknownSession` | `:77-82` |
| 保留 host 冲突 | `lib` 保留；session id 应是 UUID 格式 | `:198-200` |
| 写/代理/桥 | 只处理 GET，无网络、无 message handler | `:385-393`、类注释 |
| 任务已取消还回调 | `stopped` 集合 + `deliverIfRunning` | `:316-374` |
| 大文件内存爆 | 1 MiB 分块 | `:378` |
| 路径信息泄露 | 错误只回 `didFailWithError`，页面看不到目录列表 | `:498-501` |

**建议补充**：

- `validatedRelativePath` 目前允许空路径？不，`components.isEmpty` 会拒绝；但 `pdsh-page://S/` 这种根请求会 `invalidPath`，可接受；
- 建议把 session id 校验成 UUID（36 字符），避免 `lib` 之外的任意 host 被当 session；
- `Content-Type` 用白名单而不是"扩展名直接拼"，避免 `text/html` 被错误地给到 `.svg`（SVG 里可含脚本）——现在 SVG 是 `image/svg+xml`，WKWebView 当图片渲染，OK；但要确保 `.svg` 页面的 CSP 也生效（目前 CSP 只对 `isHTML` 注入，`:454-458`）。**建议对 `.svg` 也注入 CSP 或直接用 `UIImage` 渲染**。

### 6.3 CSP 三档（现状 + 建议）

现状（`PageSchemeHandler.swift:248-266`）：

```
default-src 'none';
script-src 'unsafe-inline' blob: pdsh-page:;
style-src 'unsafe-inline' pdsh-page:;
img-src data: blob: pdsh-page:[ https:];
font-src data: pdsh-page:[ https:];
media-src pdsh-page:[ https:];
connect-src 'none' | pdsh-page:[ https:];
frame-src 'none';
worker-src blob: pdsh-page:;
object-src 'none';
base-uri 'none';
form-action 'none'
```

建议：

- 加 `frame-ancestors 'none'`（防被别的页面 frame；虽然自定义 scheme 本来也难被 frame）；
- 加 `sandbox allow-scripts`？**不要**——`sandbox` 会强制唯一 origin，`localStorage`、同源 fetch、module 全废；三档已经用 `default-src 'none'` 收口，不需要 sandbox 指令；
- `online` 档的 `https:` 只加在 `img/font/media/connect`，不要加 `script-src https:`（否则页面可拉远程 JS，等于把 CSP 的"打包脚本"原则破掉）；如果必须允许远程脚本，单独做一档并明确 UI；
- `worker-src blob: pdsh-page:` 保留（three.js/Worker 需要）；但注意 WKWebView 没有 SW，Worker 是普通 Worker，可用；
- 页面**不能**放宽 header CSP：多个 CSP 取交集，`<meta>` 只能加严，不能放松。这是 header 注入方案的核心优点。

### 6.4 网络 kill-switch（可选，纵深防御）

CSP 是页面级；`WKContentRuleList` 是 WebView 级，能拦住 CSP 漏掉的请求（比如页面用 `new Image().src` 到远程，CSP 已拦，但规则列表可以再兜一层）：

```swift
let rules = """
[{"trigger":{"url-filter":"^https?://","resource-type":["document","image","style-sheet","script","font","media","fetch","websocket","raw"]},
  "action":{"type":"block"}}]
"""
WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "pdsh-preview-offline", encodedContentRuleList: rules) { list, error in
    if let list { configuration.userContentController.add(list) }
}
```

注意：这会**连 localhost 一起拦**，所以只在"离线档"的预览 WebView 上装；localhost 面用另一个 configuration。规则列表不替代 CSP，只是兜底。**[SDK]**

### 6.5 JS 桥：默认没有，将来也只在"显式动作"上开

现状正确：`PageSurface.swift:126-129` 明确不装 message handler；`WebEngineNativePreview.swift` 的 `pdshNativePreview` 桥是给旧 Web 面的，`01-current-ios.md` 已认定它是死代码。

如果将来必须加桥（例如"在预览页里点分享"）：

```swift
// 只挂到专用 world，不污染页面 world
configuration.userContentController.addScriptMessageHandler(
    handler, contentWorld: .init(name: "pdshPreviewBridge"), name: "pdshPreview")
// 收到消息后（`protocol` 是 Swift 关键字，成员访问写 `securityOrigin.\`protocol\``）：
let origin = message.frameInfo.securityOrigin
guard message.frameInfo.isMainFrame,
      origin.host == expectedSessionID,
      origin.`protocol` == "pdsh-page" else { return }
```

再加：消息 schema 版本、长度上限、控制字符拒绝、一次只处理一个请求、超时、回调用 `window.__PDSH_RESULT__` 而不是 `alert`。**没有用户手势触发的桥调用一律拒绝。**

### 6.6 导航 / 下载 / 上传 / 弹窗 / 媒体权限

| 入口 | 策略 | API |
|---|---|---|
| 主框架导航到非预览 origin | `.cancel` + 提示"已阻止页面跳转"（现状 `PageSurface.swift:187-195` 只对 scheme 判断，建议加 origin 精确比较） | `WKNavigationDelegate.decidePolicyFor navigationAction` |
| `target=_blank` / `window.open` | 返回 nil（不创建新 WebView） | `WKUIDelegate.createWebViewWith` |
| 下载 | 默认拒绝；需要时走显式用户确认，落到临时目录（**不落 workspace**），完成后提示/删除 | `WKNavigationAction.shouldPerformDownload`（iOS 14.5+）、`.download` policy、`WKDownloadDelegate` |
| `<input type=file>` | 返回 nil（预览页不该读用户文件） | `WKUIDelegate.runOpenPanelWithParameters`（iOS 18.4+） |
| JS `alert/confirm/prompt` | 实现并抑制/转成非阻塞提示 | `runJavaScriptAlertPanel...` 等 |
| 摄像头/麦克风 | `.deny` | `requestMediaCapturePermissionForOrigin`（iOS 15+） |
| 设备方向/运动 | `.deny` | `requestDeviceOrientationAndMotionPermissionForOrigin`（iOS 15+） |
| 外链点击 | 确认后 `SFSafariViewController`/`UIApplication.open`，**不在预览 WebView 内导航** | `decidePolicyFor` + `navigationType == .linkActivated` |
| WebContent 崩溃 | 重建并提示，不静默白屏 | `webViewWebContentProcessDidTerminate` |
| Lockdown Mode | 强制 sandbox 档，禁 online；首次提示可用 `showLockdownModeFirstUseMessage` | `WKWebpagePreferences.isLockdownModeEnabled`、`WKUIDelegate`（iOS 16+） |

### 6.7 数据存储与清理

- **工作区 HTML**：`WKWebsiteDataStore.nonPersistent()`（仓库已用，`PageSurface.swift:122`）。每次预览一个新的 store，关闭即清；`localStorage` 只在本次预览内有效。
- **需要跨预览保留状态**（比如 3D demo 的相机位置）：用 `dataStore(forIdentifier:)`（iOS 17+）给每个 session 一个 UUID store，并在"清除预览数据"时 `removeDataStore(forIdentifier:)`。**[SDK]**
- **localhost 面**：单独 store，per-origin；关闭时删除（避免 cookie 残留）。
- **cookie 清理**：`WKHTTPCookieStore.delete(_:)` / `removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince:)`。
- **不要**用 `.default()` 给工作区 HTML —— 会把预览页的 localStorage 和主 Web 面的 `dsh.sessions.current` 混在一起。

### 6.8 Info.plist / entitlements 精确清单（针对预览）

**必须（现状已满足）**

| 键 | 值 | 作用 |
|---|---|---|
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | `true` | 声明本地网络意图；覆盖 unqualified/.local/IP |
| `NSAppTransportSecurity` → `NSExceptionDomains` → `127.0.0.1` / `localhost` | `NSExceptionAllowsInsecureHTTPLoads = true` | 明文 loopback 的显式例外（实测 WKWebView 不写也行，但原生 URLSession/旧系统需要；作为声明保留） |
| `NSLocalNetworkUsageDescription` | 现有文案 | **只为 MCP/局域网场景**；localhost 预览不需要它 |
| `NSBonjourServices` | `_pdsh._tcp.` | 只为 MCP 发现；预览不要新增类型 |

**建议补**

| 键 | 值 | 理由 |
|---|---|---|
| `NSExceptionDomains` → `::1` | `NSExceptionAllowsInsecureHTTPLoads = true` | `localhost` 可能解析到 IPv6；补上更稳 |
| （无） | — | 不需要任何 entitlement；`WKURLSchemeHandler`、WKWebView、PDFKit、AVKit、QuickLook 都不需要额外 entitlement |

**明确不要**

| 键/entitlement | 为什么不要 |
|---|---|
| `NSAllowsArbitraryLoads` | 全 App 放开 HTTP，过宽 |
| `NSAllowsArbitraryLoadsInWebContent` | 上架要写理由；预览不需要（实测 loopback 不需要） |
| `com.apple.developer.networking.multicast` | 预览不做组播/任意 Bonjour |
| `com.apple.developer.web-browser` | 那是默认浏览器/替代引擎相关，不是 WKWebView 预览 |
| `WKAppBoundDomains` + `limitsNavigationsToAppBoundDomains` | 会锁死域名，用户 localhost 端口/主机不可预知 |
| `NSPhotoLibraryUsageDescription`（为预览） | 用 PHPicker 就不需要 |

**现有 `Info.plist` 的一个真实缺陷**：`examples/probe-app/Config/PhoneDSHProbe-Info.plist` 里手机权限块**重复了两遍**（`65-96` 与 `101-132` 行，`NSCalendarsFullAccessUsageDescription` 等）。`plutil`/Xcode 会保留后一份，所以现在能跑，但应去重，避免以后改一份漏一份。这与预览无关，但顺手记录。

**entitlements**：`Config/PhoneDSHProbe.entitlements` 只有 HealthKit/HomeKit/keychain-access-groups；预览不需要新增。文件访问全部在 App 容器内（`Documents/chat-host/...`），不需要 security-scoped bookmark；如果将来要预览"文件"App 里的外部文件，用 `UIDocumentPickerViewController` 拿 URL 后 `startAccessingSecurityScopedResource()`，**只读、用完 stop**。

---

## 7. 预览路由建议（供实现直接照抄）

### 7.1 文件类型 → 渲染器 → 深度

| 类型（UTI / 扩展名） | 渲染器 | 深度 | JS | 网络 | 失败兜底 |
|---|---|---|---|---|---|
| `public.html`（`.html/.htm`） | `pdsh-page://` + `PDSHPageView` | D2 内联 | 产品开关，默认开 | 按页面 CSP 档 | 源码文本 + 分享 |
| `public.svg-image` | WKWebView 关 JS（原生无 SVG 光栅化器） | D2 内联 | **关** | 无 | 分享 |
| `com.adobe.pdf` | PDFKit | D2 内联 | — | 无 | QL 全屏 |
| `public.image` 系（png/jpeg/heic/gif/webp/avif） | ImageIO + `UIImageView` | D2 内联；D1 单图 | — | 无 | QL |
| `public.mpeg-4`/`com.apple.quicktime-movie`/`com.apple.m4v-video` | `AVPlayerViewController` | D2 内联 | — | 无 | QL |
| `public.mp3`/`com.apple.m4a-audio`/`com.microsoft.waveform-audio` | `AVPlayer` | D2 内联（小播放条） | — | 无 | QL |
| Office（docx/xlsx/pptx/doc/xls/ppt） | Quick Look | **全屏** | — | 无 | 分享/打开方式 |
| iWork（pages/numbers/key） | Quick Look | 全屏 | — | 无 | 分享 |
| `public.comma-separated-values-text`/`public.tab-separated-values-text` | 原生网格 | D2 内联 | — | 无 | 文本 |
| 文本/代码/JSON/Markdown | 原生文本/Markdown | D2 内联 | — | 无 | 分享 |
| `org.khronos.glb`/`gltf` | `pdsh-page://` + three.js | D2 内联 | 开 | 按 CSP 档 | 分享 |
| `com.pixar.universal-scene-description-mobile`（usdz） | Quick Look（AR） | 全屏 | — | 无 | 分享 |
| `public.zip-archive` / 未知 | `QLPreviewController.canPreview` 判断 | 全屏/分享 | — | 无 | 分享 |
| `http(s)://` / `localhost` | 独立 Web 面 | 全屏 | 开 | 该 origin 自己的策略 | 系统浏览器 |

UTI 已用 `UTType(filenameExtension:)` 在本机核对（附录 C）。

### 7.2 深度与呈现

| 深度 | 内容 | 渲染器限制 |
|---|---|---|
| D1 peek | 文本前 N 行、单图、PDF 第 1 页缩略图、HTML 缩略图/标题 | **不挂真渲染器**（不启 WebView、不解析 PDF 全文） |
| D2 preview | 上述内联渲染器 + 头部（标题/类型/大小/脚本 chip/CSP chip/更多） | Office、USDZ 只能"打开"进全屏 |
| 全屏 | Office QL、USDZ AR、localhost/Web 面 | 都是独立 modal/push |

### 7.3 localhost 预览模式（独立流程）

```
用户动作（粘贴 URL / 点 http://localhost 链接 / 扫码）
  → 解析并校验：scheme ∈ {http,https}；host ∈ {127.0.0.1, localhost, ::1}（v1 只允许 loopback）
  → 确认卡：显示 origin + "这是本机服务，不是工作区文件" + 打开/取消
  → 新 WKWebView（独立 configuration + 独立 dataStore + 无桥 + 无 token）
  → 导航白名单 = 该 origin；外链取消并提示
  → 加载失败：超时 10 s → "服务没有响应" + 重试 + 在系统浏览器打开
  → 关闭：释放 WebView + 删除 store
```

**v1 不做**：mDNS/Bonjour 发现、局域网 IP、任意端口扫描、把 localhost 页面嵌进 `pdsh-page://` 页面。

### 7.4 JS opt-in 的 UI 语义

- 工作区 `.html`：默认开，头部 chip `脚本开`；关闭后 reload，页面会退化（three.js 不跑），显示一行说明；
- `.svg`：默认关，不提供开关；
- localhost 面：默认开，无开关（它就是网页）；但必须显示"本机服务"标识；
- Lockdown Mode：强制关/强制 sandbox，chip 显示 `Lockdown`；
- 任何"关 JS"都**不是**安全边界（`WKUserScript` 仍执行），要写进实现注释。

### 7.5 错误与降级状态机

| 状态 | 触发 | UI | 出路 |
|---|---|---|---|
| reading | 打开中 | 标题 + 骨架/进度 | 取消 |
| ok | 渲染成功 | 内容 + 头部 | 关闭/分享/更多 |
| empty | 0 字节 | "空文件" | 分享 |
| tooLarge | 超过渲染预算（如 HTML > 8 MiB、文本 > 8 MiB） | 说明 + 大小 | 分享/打开方式 |
| unsupported | 没有渲染器 | "iOS 不能预览这种格式" | 分享/打开方式 |
| encrypted | PDF/Office 加密 | "需要密码" | 分享 |
| missing | 文件不在物化快照 | "文件还在写入或已移动" | 重试/刷新工作区 |
| blocked | 导航被拦 | "已阻止页面跳转" | 返回/在浏览器打开（仅 http） |
| webContentCrash | WebContent 被杀 | "页面已重新加载"（自动重建一次） | 重试 |
| serviceDown | localhost 连不上 | "服务没有响应" | 重试/换端口 |
| noServiceWorker | 页面需要 SW（检测 `'serviceWorker' in navigator` 失败 + 页面报错） | 顶部提示"WKWebView 不支持 Service Worker" | 继续只读/换浏览器 |

### 7.6 实施顺序（平台侧，不含 UX 重构）

| 阶段 | 内容 | 依赖 |
|---|---|---|
| **P0** | 保留 `pdsh-page://` 作为 HTML 主路径；删 `javaScriptEnabled` 旧 API；CSP 增加 `frame-ancestors`；SVG 也注入 CSP；`::1` ATS 例外；`EmbeddedQuickLook` 改为顶层 present 或标记实验 | 现有代码 |
| **P0** | PDF → PDFKit；视频 → AVPlayerViewController；图片 → ImageIO 降采样（替换 QL 万能路径） | 新原生视图 |
| **P1** | localhost 独立 Web 面（独立 dataStore + 导航白名单 + 无桥 + 超时/错误态） | 新路由 |
| **P1** | CSV/TSV 网格；文本 8 MiB 流式读（去掉 256 KiB/200 行） | 现有限额 |
| **P2** | xlsx 解析（第三方）或保持 QL；USDZ AR；`WKContentRuleList` 离线 kill-switch；iOS 26.5 `securityRestrictionMode` 评估 | — |

---

## 附录 A — 实测方法与原始数据

**探针 app**（仓库外，`/tmp/pdsh-preview-probe`）：

- 手写 `Info.plist`，`swiftc -parse-as-library -target arm64-apple-ios26.5-simulator -sdk <iPhoneOS26.5.sdk> -framework UIKit -framework WebKit`；
- `UIApplicationDelegate` + 1×1 可见 `WKWebView`（iOS 上 detached WebView 会被节流）；每个 case 新建 configuration；
- `WKURLSchemeHandler` 注册 `probe`，提供 `probe://test/*`（无 ACAO）、`probe://lib/*`（ACAO `*`）、`probe://lib2/*`（无 ACAO）；
- 页面脚本用 `webView.callAsyncJavaScript` 执行并返回 JSON；
- 本地 HTTP：`python3 -m http.server 8791`（无 CORS）与自带 `Access-Control-Allow-Origin: *` 的 8792；
- 安装/运行：`xcrun simctl install 65F16681-... Probe.app`、`xcrun simctl launch --console-pty ...`；结果同时写 `Documents/probe-result.json`。

**关键原始值（iOS 26.5 模拟器，2026-11-01；多轮运行合并展示，凡标注的能力在各轮均复现）**：

```json
{
  "customScheme": {
    "href": "probe://test/index.html", "origin": "probe://test", "secure": true,
    "localStorage": "probe-value", "cookie": "",
    "fetchSame": 200, "moduleSame": "module-ok",
    "fetchCrossCors": 200, "fetchCrossNoCorsError": "TypeError: Load failed",
    "moduleCrossCors": "cors-module-ok", "moduleCrossNoCors": "nocors-module-ok",
    "fetchCorsHttpFromPage": 200,
    "hasSW": false, "hasSubtle": true
  },
  "fileURL": {
    "origin": "file://", "secure": true, "localStorage": "probe-value", "cookie": "probeCookie=1",
    "fetchSameError": "TypeError: Load failed",
    "moduleSameError": "TypeError: Cross-origin script load denied by Cross-Origin Resource Sharing policy.",
    "hasSW": false, "hasSubtle": true
  },
  "htmlString": {
    "origin": "null", "secure": false, "localStorageError": "SecurityError: The operation is insecure.",
    "fetchSameError": "TypeError: URL is not valid or contains user credentials.",
    "moduleSameError": "TypeError: Module name, './mod.js' does not resolve to a valid URL.",
    "hasSW": false, "hasSubtle": false
  },
  "httpLoopbackIP": {
    "origin": "http://127.0.0.1:8791", "secure": true, "localStorage": "probe-value",
    "fetchSame": 200, "moduleSame": "module-ok", "hasSW": false, "hasSubtle": true
  },
  "httpLocalhost": {
    "origin": "http://localhost:8791", "secure": true, "fetchSame": 200,
    "moduleSame": "module-ok", "hasSW": false, "hasSubtle": true
  },
  "httpPersistent": { "secure": true, "hasSW": false, "fetchSame": 200 }
}
```

**同一探针去掉 `NSAppTransportSecurity` 全部键后重装重跑**：`httpLoopbackIP` / `httpLocalhost` 仍 `secure: true`、`fetchSame: 200`。→ loopback 在 WKWebView 里不依赖 ATS 例外。

---

## 附录 B — 未验证项（不要当事实引用）

1. **真机**（非模拟器）上的同一矩阵：尤其 `isSecureContext`、localStorage、模块、service worker、ATS、本地网络权限。模拟器与真机在本地网络隐私上明确不同（TN3179）。
2. **Lockdown Mode** 下的 `isSecureContext` / WebGL / module 行为（推测：secure context 不变，JIT 关闭，WebGL 可能降级）。
3. **iOS 26.5 `securityRestrictionMode = .maximizeCompatibility`** 对 three.js 首帧/fps 的实际影响（未跑）。
4. **自定义 scheme 页面 iframe 到 `http://127.0.0.1`** 是否被 mixed content 拦（本探针只测了 fetch；fetch 带 CORS 时 200）。
5. **`localhost` 在真机上解析到 `::1` 时的行为**（服务器只 bind IPv4 时是否会回退）。
6. **cookie 在自定义 scheme 下的服务端语义**（`document.cookie` 写入无效已实测；响应头 `Set-Cookie` 是否被存未测）。
7. **Range 与 `<video>` 在自定义 scheme 下的 seek**（仓库实现了 206，但未在真机大文件上验证）。
8. **`WKContentRuleList` 是否拦截自定义 scheme 请求**（未测；预期只匹配 http(s)）。
9. **QL 在 iOS 26.5 上内联子 VC 的真实行为**（仓库现有 `EmbeddedQuickLook` 在跑，但未做交互/旋转/键盘验收）。
10. **xlsx 第三方解析**的可行性/包体/许可证（未选型）。

---

## 附录 C — 参考

**Apple 文档（本次实际取用）**

- [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) — iOS 17+ IP 默认收紧、例外写法
- [NSExceptionDomains](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains) — IP/CIDR、不能带端口/通配
- [NSAppTransportSecurity](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity) — 版本化行为
- [NSAllowsArbitraryLoadsInWebContent](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent) — 上架需理由
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — WKWebView 流量豁免、模拟器不实现
- [Preventing Insecure Network Connections](https://developer.apple.com/documentation/security/preventing-insecure-network-connections) — ATS 只作用于 URL Loading System
- [WKURLSchemeHandler](https://developer.apple.com/documentation/webkit/wkurlschemehandler)、[loadFileURL(_:allowingReadAccessTo:)](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:))
- [Quick Look](https://developer.apple.com/documentation/quicklook)、[QLPreviewController](https://developer.apple.com/documentation/quicklook/qlpreviewcontroller) — 支持类型、内联限制
- [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)

**SDK 头文件（逐行核对）**

- `.../iPhoneOS26.5.sdk/System/Library/Frameworks/WebKit.framework/Headers/`
  - `WKPreferences.h:115`（`javaScriptEnabled` 废弃）
  - `WKWebpagePreferences.h:59-71`、`:104-121`（`allowsContentJavaScript`、`securityRestrictionMode` iOS 26.5）
  - `WKWebViewConfiguration.h:215-227`（scheme handler 注册规则）、`:110`（`WKProcessPool` 废弃）
  - `WKWebView.h:132`、`:139`、`:677`（`loadFileURL`、`loadHTMLString`、`isInspectable`）
  - `WKURLSchemeTask.h`（CORS 头、stop 后回调抛异常）
  - `WKWebsiteDataStore.h:104-117`（`dataStore(forIdentifier:)` / `removeDataStore(forIdentifier:)` iOS 17+）
  - `WKDownloadDelegate.h`、`WKNavigationAction.h:82`（`shouldPerformDownload` iOS 14.5+）
  - `WKUIDelegate.h:295`（`runOpenPanelWithParameters` iOS 18.4+）
- `PDFKit.framework/Headers/PDFView.h`、`PDFDocument.h`
- `AVKit.framework/Headers/AVPlayerViewController.h`
- `PhotosUI.framework/Headers/PHLivePhotoView.h`、`PHPicker.h`
- `QuickLook.framework/Headers/QLPreviewController.h`、`QLPreviewingController.h`
- `QuickLookThumbnailing.framework/Headers/QLThumbnailGenerator.h`

**仓库内证据**

- `spec/v1/render-media-v1.md`（PAGE 面、三档 CSP、3D、失败降级）
- `Sources/PhoneDSHEngine/PageSchemeHandler.swift`（scheme、校验、Range、CSP）
- `Sources/PhoneDSHEngine/PageSurface.swift`（WebView 装配、错误条、导航拦截）
- `Sources/PhoneDSHEngine/WebEngineConfiguration.swift`（loopback origin、port pinning）
- `Sources/PhoneDSHLoopback/LoopbackServer.swift`（如果要走方案 B）
- `examples/probe-app/PhoneDSHProbe/FilesPage.swift:296-487`（现有 QL 内联）
- `examples/probe-app/ProbeKit/Office/OfficePresenter.swift:90-135`（顶层 present QL 的正确写法）
- `docs/design/security-checklist-2026-10-31.md` §1（loopback 不是信任边界）
- `$TMPDIR/pdsh-probes/probe-report.json`（macOS 旧探针，注意平台差异）
