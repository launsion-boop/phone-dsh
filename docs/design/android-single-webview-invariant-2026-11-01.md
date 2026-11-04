# 一个 App 只有一个 WebView（原「方案 §6.3-5」）

**状态**：现行不变式。**本文是它的规范之家**——在此之前，它只以「§6.3-5」这个名字被代码和契约反复引用，而那份方案的正文不在本仓库里，任何一条车道想裁决「能不能开第二个 WebView」都只能重新推导一次。

- 提出：2026-10-31 的 Android 移植方案 §6.3 第 5 条
- 落文：2026-11-01（PR15 预览面要求 HTML/3D 渲染，第三次撞上这条不变式）

## 一句话

**一个 App 进程只构造一个 `WebView`。** 第二个会在 `:engine` 里以 `IllegalStateException` 大声失败，而不是静默地去抢 renderer。

## 它在代码里的三个位置

| 位置 | 内容 |
|---|---|
| `android/engine/.../WebViewEngine.kt:1255` | `liveWebViews` —— **进程级**计数 |
| `android/engine/.../WebViewEngine.kt:605-609` | `createWebView()` 里的断言：已有实例就抛 |
| `android/engine/.../DemoEngine.kt:5-8` | `DemoEngine` 的**门面**不暴露 `WebView`，所以按门面写代码的车道构造不出来 |
| ⚠️ **这条不是强制的** | `android/app/.../ProbeEngineViewModel.kt:11` 直接 `import android.webkit.WebView`（只用来读 kernel 包名）。**`:app` 编译期看得见 `android.webkit`**，自己 `WebView(context)` 不会经过 engine 的计数器，却共享同一个 `CookieManager` 单例。这是本文对应的**真实缺口**：断言只挡得住从 `:engine` 走的人 |

## 为什么存在：写下来的理由全是资源/正确性

1. **Chromium 一个 App 只跑一个 renderer**（`WebViewEngine.kt:4-11`）。
2. **WebView 绑在拥有它的 view thread 上**（App 进程 = UI 线程）；在别处构造会抛异常或损坏 renderer host（`:593-600`）。
3. **一个构造点 = 一个跳闸点**，让「谁又开了一个 WebView」变成编译期/启动期的可见错误，而不是运行期的偶发崩溃。

**这三条都没有把它写成安全边界。** 仓库真正的隔离条款是另外几条：`spec/v1/bridge.md` 的 bridge 同源主 frame、release 关调试、loopback launch token、以及禁 `file:` / `content:` / `universalFileAccess`。

## 但它今天在效果上承担了隔离

这是本文件存在的真正理由。证据链都在本仓库：

1. 页面唯一的凭据是 D22 launch cookie（`android/net/.../LaunchCookie.kt`）。
2. `LoopbackService.isAuthorized` 把 `LaunchCookie.value(...)` 对**每条路径**都当凭据（`LoopbackService.kt:225-232`）。
3. **`CookieManager` 是应用级单例**，engine 用 `CookieManager.getInstance()` 种 cookie（`WebViewEngine.kt:801-806`）。
4. 主页面 JS 还持有 launch token（URL 下发，已知欠账）。

⇒ **同进程里的第二个 WebView 共享同一个 cookie jar 和同一个 renderer。** 于是「工作区里一个恶意 `.html`」到「host 能力面」之间，这条不变式是最后一道墙。

## 因此：可以放宽，但不能按「独立实例」放宽

**「独立实例 + 独立 `NavigationPolicy` + 用完销毁」接管不了上面那份隔离**——同进程就是同一个 cookie jar、同一个 renderer。

要做 HTML / 3D 预览（PR15 的 `PreviewSurface` 支持它们），B 方案**必须**是：

1. **独立进程**（`android:process=":preview"`），这样 cookie jar 与 renderer 都不共享；
2. `:engine` 从「一个 WebView」改成「一个主 WebView + 最多一个预览 renderer」的**带标签计数**（仍然 loud）；
3. **预览专用窄策略**，且必须用 `shouldInterceptRequest` 按 host 拦——`shouldOverrideUrlLoading` 只看导航，**子资源请求和 WebSocket 不走它**；默认 `setBlockNetworkLoads(true)`，按次授权才放开；
4. 页面源 + CSP 三档 + 禁弹窗 / 禁 file chooser；3D 要离线打包 three.js（含 license）；
5. 四条必备测试：① 预览 WebView 导航到外网 / loopback / `file:` / `content:` / `data:` 全被拒；② 预览页内 `document.cookie` 为空且 `window.__PDSH_BRIDGE__` 未定义（engine 今天没有任何 `addJavascriptInterface`，这是回归护栏）；③ 销毁后 `liveWebViewCount()` 回到 1；④ 主页面 origin 从预览页不可读。

## 改它的流程

1. **先改本文**（范围、理由、上面 5 条）。
2. 再改 `spec/v1/bridge.md:156`「One WebView per app process」——它是目前唯一的规范句。
3. 再改 `spec/ui/v1/pages/preview-surface.json` 的 `handRegistered.scope`（它正是靠这条不变式把「网页网络权限 / 重新加载页面」排除出 Android 比对集合的）。
4. 最后改代码，并补上第 5 节那四条测试。

**顺序不能反**：先改代码会留下一棵「代码 2 个 WebView / 规范 1 个」的树，那正是这类 drift 的典型形态。

## 2026-11-01 的裁决记录

PR15 的预览面要求 HTML/3D。三条独立车道（L28 / L29 / L33）先后撞上这条不变式。裁决是**保持一个 WebView**，HTML / 3D / OGV 走「诚实卡片 + 按文件写具体原因 + 分享」。理由：

- 规范上过不去（改它要同批改两份 spec，本轮不可）；
- 安全上不划算（安全版 B 是模块级项目，按「独立实例」做出的 B 是**看起来更宽、其实更弱**的假 B）；
- A 不是一次性的（B 落地后诚实卡片仍然正确）。

`PreviewUnsupported.kt` 把「架构真正 gate 的集合」定成 `{HTML, MODEL}`——`webMedia` 是三件不同的事（gif 是动效解码、webm 是播放器路由、ogv 是没有解码器），不该和架构混为一谈。
