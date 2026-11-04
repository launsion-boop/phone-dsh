# L10 可达性证据：从 App 首页触摸走到每个页面

本轮的目标不是「路由可达」，而是「用户手指可达」。之前每条页面证据都来自
instrumented test 里直接 `nav.push`（或直接渲染 composable），所以采集图上有、
App 里点不到。这份 receipt 记录的是后者：启动 App → 点 `☰` 打开抽屉 → 点条目 →
截图，全程真实触摸事件（`adb shell input tap`），没有一行 `nav.push`。

- 设备：自建 AVD `l10-drawer`（pixel_6, Android 15 / android-35 google_apis, arm64-v8a），
  端口 **5624**（`-no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect`）。
- 构建：HEAD `86a39aac` + 当前工作树里其他车道的页面（17:08 快照）+ 本车道 4 个文件；
  详见 [Provenance](#provenance)。
- 驱动脚本：[capture.py](capture.py)（每一步都用 `uiautomator dump` 找 semantics
  节点，再 `input tap` 节点中心；截图是 `screencap`）。

## 1. 抽屉现在有什么

`HostShell.kt` 的 `DRAWER_ENTRIES` / `DRAWER_FOOTER_ENTRIES` 一共 8 行，全部在
首屏可见，不需要滚动：

| 行 | 路由 | 目的页面 |
|---|---|---|
| 对话 | `PdshRoute.Chat` | `ChatPage` |
| 会话 | `PdshRoute.Sessions` | `HostSessionsScreen`（宿主真实会话读） |
| 工作文件夹 | `PdshRoute.WorkspaceFolders` | `WorkspaceFoldersPage` |
| 命令 | `PdshRoute.Tools` | `PDSHShellPage` |
| 设备连接 | `PdshRoute.DeviceConnection` | `NativeDeviceConnectionPage` |
| DSH 页面 | `PdshRoute.WebSurface` | 引擎 WebView |
| 定时任务（底部组） | `PdshRoute.Automation` | `NativeAutomationPage` |
| 设置（底部组） | `PdshRoute.Settings` | `SettingsPage` |

`01-drawer.png` 是抽屉本身（320 pt 面板 + 右侧遮罩 + 底部组）。

## 2. 逐页触摸证据（启动 → 点抽屉 → 点条目 → 截图）

所有截图都在 `screens/`，每张都在同一次 `am start` 会话里由
`☰ → 条目` 两次真实触摸得到；页面文字来自同一时刻的 `uiautomator dump`。

| 入口 | 路由 | 截图 | 页面关键文字（uiautomator） |
|---|---|---|---|
| 对话 | `Chat` | [10-chat.png](screens/10-chat.png) | `新会话`、`引擎还没启动`、`启动本地引擎`、`发消息或创建任务…`；宿主 note `只读：本宿主未接入会话记录的读取` |
| 会话 | `Sessions` | [11-sessions.png](screens/11-sessions.png) | `会话列表`、`搜索会话`、`新建会话`、`添加工作文件夹`、`已归档` |
| 工作文件夹 | `WorkspaceFolders` | [12-workspace-folders.png](screens/12-workspace-folders.png) | `工作文件夹`、`添加`、`宿主未提供写命令：本页只读`、`未知. 宿主没有报告工作文件夹…` |
| 命令 | `Tools` | [13-tools-commands.png](screens/13-tools-commands.png) | `命令`、`这台手机`、`状态 未链接或未配置`、`还没接上命令` |
| 设备连接 | `DeviceConnection` | [14-device-connection.png](screens/14-device-connection.png) | `Device`、`真实连接设备`、`注入的连接器`、`客厅网关`、`esp32-8c4f01`、`传输能力` |
| 设备会话（设备行二次点击） | `DeviceSession` | [20-device-session.png](screens/20-device-session.png) | `设备会话 · 只读监视`、`客厅灯已经到 40%。`、`light.set`、`已完成`、`思考` |
| 定时任务 | `Automation` | [15-automation.png](screens/15-automation.png) | `✕`、`刷新`、`新建`、`定时任务`、`定时任务状态未知` |
| 设置 | `Settings` | [16-settings.png](screens/16-settings.png) | `通用设置`、`通用 模型 插件 手机权限 预设`、`权限 未设置` |
| DSH 页面 | `WebSurface` | [17-dsh-web-surface.png](screens/17-dsh-web-surface.png) | WebView 真渲染：`DSH phone worker`、`worker ready` |

另外两张是「进去之后按钮真的能用」，不是静态渲染：

- 定时任务页 `刷新` / `新建`：见 [15b-automation-refresh.png](screens/15b-automation-refresh.png)、
  [15c-automation-new.png](screens/15c-automation-new.png)。
  点击后宿主 note 与 logcat 同时出现（`logs/automation-bar.log`）：
  `PDSHNav: host action handed off: automation.refresh` /
  `host action handed off: automation.editor`。
- 会话页 `新建会话`：见 [18-sessions-host-handoff.png](screens/18-sessions-host-handoff.png)。
  这一步同时证明「会话」不是 `PdshNavHost` 里只读 facts 的空列表，而是宿主真实的
  会话读（`logs/sessions-host-handoff.log`，`PDSHSessions: host session gesture
  handed off: new`）。

## 3. 抽屉对齐（iOS 是权威）

iOS 的抽屉本体：`SessionsDrawer` = `SessionsPage`（会话列表）+ 底部两行
`定时任务` / `设置`（`NativeShell.swift:276-317`），导航栏隐藏
（`NativeShell.swift:291`），所以抽屉里没有搜索框、没有大标题。底部行
`DrawerRow` 的尺寸在 `NativeShell.swift:411-436`。

Android 没有 tab bar、根页面是引擎探针而不是会话列表，所以抽屉做成了纯导航表：
上面 6 行是本 App 的地图，下面 2 行对齐 iOS 的底部家具行。

| 量 | iOS 出处 | iOS 值 | Android 实现 | 设备实测（1080×2400 @2.625） |
|---|---|---|---|---|
| 面板宽 | `NativeShell.swift:97` | 320 pt | `SessionsMetrics.drawerWidth` | 840 px = **320.0 dp**（PNG 边缘 839 px） |
| 内容宽 | `SessionsPage.swift:593`（320−16−16） | 288 pt | `SessionsMetrics.drawerContentWidth`；行内边距 `rowInset=16` | 840 − 2×42 = 756 px = **288.0 dp** |
| 行高 | `NativeShell.swift:433` | 48 pt | `SessionsMetrics.drawerRowHeight` | 126 px = **48.0 dp**（8 行等距） |
| 图标槽 | `NativeShell.swift:422` | 22 pt | `SessionsMetrics.drawerRowIconSlot` | 槽位 42..100 px = **16..38 dp（22 dp）** |
| 图标/标题间距 | `NativeShell.swift:419` | 10 pt | `SessionsMetrics.drawerRowSpacing` | 标题左边 126 px = **48 dp = 16+22+10** |
| 右侧 chevron | `NativeShell.swift:428`-`:429` | 12 pt | `SessionsMetrics.drawerRowChevron` | ink 776..788 px = **295.6..300.2 dp**（槽 292..304） |
| 面板右圆角 | `NativeShell.swift:254` | 22 pt | 背景 shape 22 dp（未 `clip`，见下） | 截图右上/右下可见 |
| 顶部起点 | 安全区 + 8 pt | — | `windowInsetsPadding(safeDrawing)` + 8 dp | 首行 top 149 px = 状态栏 128 + **8.0 dp** |
| 底部组 | `NativeShell.swift:293`-`:306` | 分隔线 + 两行 + `bottomInset+16` | 分隔线 + 两行 + 16 dp | 分隔线 y=2042 px；末行 bottom 2295 px（= 屏高 − 24 dp 手势区 − 16 dp） |

原始 semantics 证据：[logs/drawer-ui.xml](logs/drawer-ui.xml)（8 行的
`content-desc` 与 `bounds`，行宽全部 840 px、行高全部 126 px）。

两个刻意的偏差，都写进了代码注释：

1. **面板圆角只画背景、不 `clip`**：Robolectric 的 `performClick` 注入会被
   rounded clip layer 吞掉（本车道调试时复现），而抽屉必须能在 JVM 测试里被点。
   行本身是矩形，视觉上只差边缘一像素级。
2. **行标签用 `type.subheadline`（15 pt regular）**：iOS 是 17 pt regular；token
   表里最接近的 regular 样式是 subheadline。行高/槽位才是本轮对齐的实测值。

## 4. L11 的自动化栏接线

`PdshNavHost.kt` 的 `AutomationRoute` 现在把 4 个手势全部接到宿主：

```kotlin
onRefresh = { onHostAction(PdshHostAction.RefreshAutomation) },
onNewSchedule = { onHostAction(PdshHostAction.OpenAutomationEditor(null)) },
onEditSchedule = { id -> onHostAction(PdshHostAction.OpenAutomationEditor(id)) },
onLoadMoreHistory = { onHostAction(PdshHostAction.LoadMoreAutomationHistory) },
```

`NativeAutomationPage` 只在回调非 null 时画 ✕/刷新/新建（`NativeAutomationPage.kt:598`/`:607`），
所以之前 App 里没有这条 bar、采集图里却有。现在 App 里点进去就能看到（
[15-automation.png](screens/15-automation.png)），点 `刷新`/`新建` 会走宿主 handoff
并显示真实反馈（[15b](screens/15b-automation-refresh.png) / [15c](screens/15c-automation-new.png)）。

CTA 仍不出现，因为宿主 facts 是 `UNKNOWN` 而不是 `EMPTY`；CTA 属于 EMPTY 态，等宿主
有定时任务读之后才会出现。这不是没接线。

## 5. 测试与门禁

- `android/lib/src/test/kotlin/com/phonedsh/ui/nav/PdshDrawerTest.kt`（JVM / Robolectric）：
  8 行逐行点击 → 路由；面板 320、行高 48、图标槽 22、标题 x=48、scrim 关闭抽屉、8 行齐全。
- `android/lib/src/test/kotlin/com/phonedsh/ui/nav/PdshReachabilityTest.kt`：
  `Sessions` 路由优先渲染宿主传入的真实列表；无宿主列表时仍渲染 facts 页；
  Chat 头部「打开会话列表」→ push `Sessions`；抽屉「会话」行 → 同一路由；
  定时任务 `刷新`/`新建` → 两个 host action。
- `./gradlew :lib:testDebugUnitTest --tests "com.phonedsh.ui.nav.*"`：
  **15 tests, 0 failures**（上面的 12 个 + `PdshSettingsRouteTest` 3 个）。
- `./gradlew :lib:testDebugUnitTest`（全套）：**本车道收尾时被其他车道的测试源挡在
  编译阶段**，与抽屉无关：
  - `BGroupRosterPagesStateTest.kt:112` 引用 `UiStrings` 但没 import；
  - `ChatPreferencesPageTest.kt:173` 的 `onFirst` 在当前 Compose 测试版本解析不到；
  - 更早一次全套跑（其他车道当时的状态）是 524 tests / 1 failed：
    `PageTokenReferenceTest` 对 `EgressAllowListPage.kt` 的 token 清单断言。
  这三个都是 settings 族车道的文件，不在本车道可写集，未改。
- `./gradlew :app:assembleDebug`：`BUILD SUCCESSFUL`（证据 APK 即此构建）。

## 6. Provenance

**本车道改的可写文件（交付 diff 只有这些）：**

1. `android/app/src/main/kotlin/com/phonedsh/probe/HostShell.kt`
   —— 抽屉换成 `PdshDrawer` + 8 行入口；`sessionsOpen` 整层删除，`PdshRoute.Sessions`
   走 `PdshNavHost(sessions = { HostSessionsScreen(...) })`；设备三页 note 改成
   「演示数据」；`Sessions` note 改 null（宿主真的读了）。收尾时其他车道把
   `PdshRoute` 扩了 6 个 settings 族路由（`AgentPresets`/`PluginInventory`/
   `PhonePermissions`/`ChatPreferences`/`SettingsDocument`/`Shortcuts`），
   `hostRouteNote` 的 `when` 必须穷尽，所以补了这 6 个 `-> null` 分支（这些页自己
   声明只读/未知；它们不是抽屉行）。
2. `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshDrawer.kt`（新）
   —— 抽屉组件、22×22 手绘图标、`PdshDrawerTags`、全部尺寸取自 `SessionsMetrics`。
3. `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshNavHost.kt`
   —— 新增可选 `sessions` slot（默认仍是原 facts 页）；`ChatRoute` 的会话控制
   push `Sessions`；`AutomationRoute` 接 4 个 host action。
4. `android/lib/src/main/kotlin/com/phonedsh/ui/SessionsMetrics.kt`
   —— **仅追加** 4 个 dp accessor：`drawerRowHeight` / `drawerRowIconSlot` /
   `drawerRowSpacing` / `drawerRowChevron`（任务要求的 `drawerRowHeight` 原本没有）。
   该文件本身是另一车道未提交的新文件（HEAD 无此文件），此处只能加不能改语义。
5. 测试：`android/lib/src/test/kotlin/com/phonedsh/ui/nav/PdshDrawerTest.kt`、
   `PdshReachabilityTest.kt`（新）。
6. `docs/receipts/l10-reachability/**`（证据）。

**构建快照（为什么不是直接在工作树里 build）：** 工作时 `:app`/`:lib` 正被其他车道
改写（`SettingsPage.kt`、`PhonePermissionsPage.kt` + `UiStrings.kt` 一度不在同一状态），
工作树会周期性变红。证据 APK 的构建方式是：

```
git archive HEAD | tar -x -C /tmp/l10-snapshot        # 86a39aac
rsync 当前工作树 android/{lib,domain,app}/src + lib/build.gradle.kts
      + spec/ui/v1/tokens.json                        # 其他车道 17:08 的页面
rsync 本车道 4 个文件 + 2 个测试
ln -s 仓库的 worker bundle / libpdsh_jni.so          # 65 MB / 109 MB 的 gitignored 构建输入
./gradlew :app:assembleDebug
```

快照里有、但我没有写回主工作树的其他车道文件：`PhonePermissionsPage.kt`、
`NativeAutomationPage.kt`、`UiStrings.kt`、`tokens.json` 等（原样拷贝，未改内容）。
仓库文件我一个都没碰：`git status` 里本车道的改动就是上面 1–6。

## 7. 边界与 open questions

1. **iOS 抽屉里没有「对话 / 命令 / 设备连接 / 工作文件夹」这四行**。iOS 的
   `NativeShell.swift` 只有会话列表本体 + 底部 `定时任务`/`设置`；对话是根面。
   Android 的根面是引擎探针，也没有 tab bar，所以这四行是为了「用户点得到」而加的，
   不是从 iOS 抄的。要不要在后续把根面改成 ChatPage（iOS 的根面），是产品决定。
2. **抽屉只能从首页打开**。routed page 上没有抽屉按钮（Chat 的「打开会话列表」只到
   会话页）。用户从 设置 想去 命令，要先返回首页再开抽屉。要补齐需要在各页头加
   统一的抽屉控制——那是页面实现文件，属于别的车道。
3. **`本 session 产物`（`SessionArtifacts`）仍无用户入口**：路由可达、三页设备族里
   只有 `DeviceConnection → DeviceSession` 这一条触摸链；产物页需要会话页/设备页里的
   一个入口，属于页面车道。L5 的这条报账没有完全关闭。
4. **对话页是空态**（宿主没有 transcript 读），note 已声明只读；这不是「点了没反应」。
5. **证据是模拟器不是物理机**：AVD android-35 arm64，1080×2400 @420 dpi。真实触摸
   事件链、渲染、WebView 都是真的；OLED/物理触感不在覆盖内。
6. **行标签字号** 15 pt vs iOS 17 pt（见 §3 偏差 2）。
