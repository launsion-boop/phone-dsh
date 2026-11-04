# 真机 vs 并排图 vs iOS：这一千行 DIFFS 对着谁在量（L86，2026-11-02）

**一句话结论：假设成立。** `docs/receipts/ui-parity-sheet/*__ios-left.png` 的 Android 那一半，
不是 App 在真机上画出来的那一帧，而是 `android/lib/src/androidTest/**` 里用手工构造的
`ChatScreenState` / `SessionsScreenState` 渲染出来的**样本**。样本对齐了 ≠ App 对齐了。

量具同一台模拟器、同一个 402×874 pt @3× 框（1206×2622 px）、同一缩放系数，
逐像素差（通道差 > 8/255 的像素占比，含状态栏与文案，只作数量级证据）：

| 状态 | 真机 vs 并排图 Android 半张 | 并排图 Android 半张 vs iOS | 真机 vs iOS |
|---|---|---|---|
| `page-sessions-empty`（首次启动首页） | **79.22 %** | **6.27 %** | **80.06 %** |
| `page-sessions-default`（有会话的列表） | 17.65 % | 13.50 % | 18.27 % |
| `page-chat-default`（聊天） | **87.54 %** | 32.19 % | 78.27 % |
| `page-settings-default`（设置） | 49.90 % | **47.87 %** | **13.70 %** |
| `page-files`（手机工作区） | 10.74 % | 11.93 % | 6.30 % |
| `page-sessions-schedules`（定时任务） | **91.87 %** | 14.02 % | **92.12 %** |

> **2026-11-02 后续（同一 lane）：首启首页已按 iOS 的 `SessionsPage` 重建，重建后同一帧对比：
> 真机 vs iOS 从 80.06 % 降到 **10.34 %**，真机 vs 并排图 Android 半张从 79.22 % 降到 **8.08 %**。**
> 见 [cmp-home-empty-after.png](cmp-home-empty-after.png) 与
> [cmp-home-empty-before-after.png](cmp-home-empty-before-after.png)。

读法：**并排图的 Android 半张贴着 iOS（6 %、14 %），真机离两边都远（79–92 %）。**
说明那半张图不是「Android 的样子」，是「照着 iOS 抄出来的样本的样子」。
`settings` 一行反过来：样本离 iOS 47.87 %，真机只离 iOS 13.70 % ——
**样本比真机更不像 iOS，却在 DIFFS 里被当成 Android 的基准**，于是把本来已经对上的地方判成差异。

## 怎么复现

```bash
# AVD：自建 pdsh-l86（android-35，pixel_6），端口 5776；不碰 5556/5558/5670–5774
emulator -avd pdsh-l86 -port 5776 -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect
# 真机帧 = 并排图帧：402×874 pt @3×
adb -s emulator-5776 shell wm size 1206x2622
adb -s emulator-5776 shell wm density 480
adb -s emulator-5776 install -r -t android/app/build/outputs/apk/debug/app-debug.apk
# 用真 fixture 走一遍产品七步，得到「有会话、有消息、有产物」的真实数据
PDSH_ACCEPT_BASE=/tmp/l86/accept PDSH_ACCEPT_EMULATOR_PORT=5776 \
  bash android/tools/acceptance/run-product-flow.sh
```

本目录的截图：APK `56d8a075b2a2b71a96c28e6c…`（HEAD `0b732a7f` + 本 lane 改动；
采集时共享工作树里另有 L85 未提交的 `ChatSurface.kt` / `ChatTurnRunner.kt` 等 app 层改动，
本 lane 没有写那些文件）。`cmp-*.png` 是三方并排：**真机 | 并排图 Android 半张 | iOS 基线**。

## 逐页：真机 vs iOS

### 1. 首页 / 会话列表（首次启动）

真机（[00-home-empty.png](00-home-empty.png)，[cmp-home-empty.png](cmp-home-empty.png)）：
`☰ 会话列表` 页头；「还差一步:配好模型服务 / 选一个模型服务,就能开始。/ 去配置模型服务」卡片；
下半屏一张居中身份卡「Phone DSH / 运行在手机端的 DeepSeek Harness / 还没有会话 / 新建会话后显示在这里」。

iOS：**没有页头**；顶部是圆角搜索框（占位符墨迹 y 392–440 px）、`+ 新建会话` 行、
`先启动本地引擎,才能新建会话。`、两份工作文件夹分组（`项目资料`、`设计稿 1`，各带 `⋯`）、
每组内 `还没有会话 / 点上面的「新建会话」开始。`、`+ 添加工作文件夹`、`> 已归档  0`。

差在哪：**iOS 会话页的整套结构在首次启动的 Android 首页上根本不存在** ——
没有搜索框、没有新建会话行、没有工作文件夹分组、没有「添加工作文件夹」、没有「已归档」。
`HostHomeScreen`（`android/app/src/main/kotlin/com/phonedsh/probe/HostSessionsScreen.kt:244`）
只在 `sessionSnapshot.waiting || sessions.isNotEmpty()` 时才渲染 `SessionsPage`，
空态渲染的是宿主自己的身份卡。两份东西不是同一页。**已修**（见 §6）：空态分支删掉，
首页永远渲染同一张 `SessionsPage`；L62 的「还差一步:配好模型服务」引导卡保留，叠在这张页之上。

### 2. 会话列表（有真实数据）

真机（[01-home-sessions.png](01-home-sessions.png)，[cmp-sessions-with-data.png](cmp-sessions-with-data.png)）：
`☰ 会话列表` 页头；搜索框文字墨迹 y 472–519 px（同一帧 iOS 是 y 392–440，**低 80 px ≈ 27 pt**）；`新会话 / 2 分钟前` 一行（右侧一个 ✓）；
分组头写着 **`未知`**，下面 **`宿主没有报告工作文件夹，无法判断有没有`**；
`+ 添加工作文件夹`；`> 已归档  未知`。

iOS：搜索框文字墨迹 y 392–440 px（同一帧，字号一致，只是位置高 27 pt）；`+ 新建会话`；`先启动本地引擎…`；
`还没有工作文件夹 / 选一个文件夹,会话和文件都放在里面。`；一颗**主按钮** `新建工作文件夹`；`> 已归档  0`。

差在哪：① 多一整行页头，把搜索框压下去 27 pt；② 分组是 `未知` + 一句宿主免责声明，
不是 iOS 的空态文案；③ iOS 的主按钮在 Android 是一条文字链；④ 已归档是 `未知` 不是 `0`。
②③④ 都来自同一个事实：**宿主不读工作文件夹**，`SessionsScreenState` 的 folders 永远是 unknown，
所以 `page-sessions-empty/default/many/ungrouped` 这四个注册状态在真机上**画不出来**。

### 3. 聊天（修前）

真机（`step7-fail.png`，见 [cmp-chat.png](cmp-chat.png) 左）：
页头标题 **`PDSH`**（App 名）、`运行中`、`⋯`；开场停在**第一条消息**；
`回到最新` 只有文字、没有箭头、底色是页面灰（等于没有胶囊）；
工具行是 `工具调用 · bash · 已停止` 和一条**只有一个点、没有名字**的 `工具调用 ·`，每个调用两条。

iOS：页头标题是会话名 / `当前会话`（有用户回合时）/ `新会话`；`已调用工具` 折叠组两行
（`工具调用 · Tests/SessionTimeTests.swift`、`工具调用 · 42 行`）；
`↓ 回到最新` 是 94×30 pt 的近白胶囊 + 0.5 pt 描边 + 箭头；正文滚到尾部。

差在哪：标题错（产品名占了会话名的位置）、恢复位置错（见下）、胶囊缺形缺箭头、
工具行每调用多画一条空行、工具状态 `已停止` 与事实不符（回答其实回来了，
只是结果节点没带 `callId`，配不上对，被 turn 收尾逻辑统一收成 STOPPED）。

### 4. 设置

真机（[04-settings.png](04-settings.png)，[cmp-settings.png](cmp-settings.png)）离 iOS 只差 13.70 %，
是六页里最接近的：白条 + 居中 `通用设置` + 5 段选择器 + 内嵌分组卡，逐行对得上。

差在哪：`完成` 是**蓝色文字、没有胶囊**（iOS 是白胶囊 + 黑字，x 302.7–389.7 / y 60.0–104.7 pt）——
**已修**；`字号大小` 右侧 Android 多一串 `17 px / 14 px / 13 px`（iOS 只有一个 `>`）；
`繁忙时的发送行为` 取值文案不同（`排到下一轮` vs `排队发送`）；`外观` 真机是 `跟随系统`（数据差，非布局）。

注意：这一页的并排图 Android 半张离 iOS 47.87 %，比真机的 13.70 % 还远 ——
**基于样本的 DIFFS 在这一页把已经对齐的东西判成了缺口。**

### 5. 文件（手机工作区）

真机（[05-files.png](05-files.png)，[cmp-files.png](cmp-files.png)）：左上角一个孤零零的 `‹`，
大标题 `手机工作区`（墨迹 y 344–440 px），搜索框（占位符 y 511–571），分组小标题，文件行（`orders-summary.md / 78 bytes` 等）。

iOS：**没有返回箭头**；标题 `手机工作区` + 右上角圆形盒子按钮；搜索框；空态 `还没有文件`。

差在哪：① Android 多一个 `‹`（iOS 这页没有返回位）；② 标题墨迹 344–440 比 iOS 376–465 高 32 px ≈ 10.7 pt，搜索占位符 511–571 比 iOS 548–596 高 37 px ≈ 12.3 pt；
③ 有数据时的分组小标题与行距是 Android 自己的（iOS 基线是空态，没有可比行）。
并排图的 Android 半张用的是**紧凑页头**（`‹ 手机工作区` 挤在一条 44 pt 栏里），
和真机的大标题布局不是同一个构图 —— 这一页的并排图从来没有比过真机的页头。

### 6. 功能页：定时任务

真机（[06-automation.png](06-automation.png)，[cmp-automation.png](cmp-automation.png)）：
最顶一条通栏 `只读：本宿主未实现定时任务存储`；`✕ 刷新 新建`；大标题 `定时任务`；
`定时任务状态未知` + `宿主没有报告定时任务，无法判断有没有；不会用 0 条代替`；`未知` + `任务数量、下次计划和投递记录都不可读`。

iOS：左上圆形刷新钮、右上 `新建` 胶囊、大标题 `定时任务`、`还没有定时任务` + `到点让它自己跑，结果回到原会话。`、
一颗蓝色主按钮 **`新建任务`**、`需要处理` + 红色宿主错误。

差在哪：**iOS 的主行动按钮 `新建任务` 在真机上完全不存在**，两段空态文案也不存在；
取而代之的是一条 Android 独有的只读横幅和四行「未知」。
并排图的 Android 半张却把 iOS 的空态 + 主按钮画得好好的 ——
**这是一个真机永远走不到、只在样本里存在的「已对齐」状态。**（91.87 % 的帧差）

## 修了什么（都修在真机看得见的地方）

| # | 修的东西 | 位置 | 改前 → 改后 |
|---|---|---|---|
| 1 | **冷启动恢复会话停在顶部** | `ui/page/ChatPage.kt` `ChatTranscript` | [cmp-chat-restore-before-after.png](cmp-chat-restore-before-after.png) |
| 2 | 聊天页头显示 App 名 `PDSH` | `ui/page/ChatPage.kt` | [cmp-chat-title-before-after.png](cmp-chat-title-before-after.png) |
| 3 | `回到最新` 缺箭头、没胶囊 | `ui/page/ChatPage.kt` | [cmp-chat-pill-before-after.png](cmp-chat-pill-before-after.png) |
| 4 | 每个工具调用多一条空行 | `ui/state/ChatScreenState.kt` `RunBuilder` | 真机 dump 从「4 条工具行（2 条为空）」变成 2 条 |
| 5 | 设置 `完成` 是蓝字无胶囊 | `ui/page/SettingsPage.kt` `SettingsBarAction` | 白胶囊 + 黑字 + hairline（同 iOS 实测框） |
| 6 | **首启首页是宿主自造的身份卡**（搜索/新建会话/工作文件夹/已归档全无） | `app/.../HostSessionsScreen.kt` `HostHomeScreen` | [cmp-home-empty-before-after.png](cmp-home-empty-before-after.png)：80.06 % → 10.34 % |

### 1）恢复会话停在顶部（L81 报的那条）

**根因（设备实测，不是猜）**：`ChatTranscript` 的 `LaunchedEffect(state.rows.size)` 用
`listState.scrollToItem(total - 1, Int.MAX_VALUE)` 想用「溢出的偏移」落到尾部，真机上没有落到任何地方；
同时这个程序化滚动会被 `snapshotFlow { isScrollInProgress to nearBottom }` 当成**用户手势**，
把 `scrolledAway` 置真 —— 于是「回到最新」浮层出现在一段没人动过的对话上，再上滚也不会自动回尾。

**改法**：
* 落尾改成「先 `scrollToItem(total - 1)`，再按 layout 量出剩余距离 `scrollBy`」，不再用 `Int.MAX_VALUE` 溢出；
* 程序化滚动期间置 `autoScrolling`，不让它写 `scrolledAway`；
* effect 的 key 从 `rows.size` 换成**行 id 序列** —— 恢复时同长度但重建行 id 会让 LazyColumn 失去锚点回到顶部，
  旧的 key 看不到这种替换。

**证据**：真机 logcat（调试期临时打的，已删除）——
`effect rows=8 away=false` → `landed first=2 offset=794 total=9`，落尾后 `near=true`；
冷启动重开同一会话的截图见 [cmp-chat-restore-before-after.png](cmp-chat-restore-before-after.png)：
左边停在第一条 `acceptance 181756 hello there`，右边停在最后一条 `…合计 325.21 … [CSV-END]`。

### 2）页头标题

iOS `ChatPage.swift:145-154 sessionTitle`：有会话名用会话名；无名字但有用户回合显示 `当前会话`；
什么都没有才 `新会话`。Android 原来 `title.ifEmpty { "PDSH" }`，把产品名画进了会话名的位置。
改成同一三段式（`当前会话` / `新会话` 用既有 `UiStrings.SESSIONS_CURRENT`、`UiStrings.NEW_SESSION`）。

### 3）`回到最新`

iOS：`Label("回到最新", systemImage: "arrow.down")`，94×30 pt 近白胶囊 + 0.5 pt 描边 + 17 pt accent 字。
Android 用了 `colors.selector`（= 页面底色 #F2F3F5）当填充，胶囊等于隐形，且没有箭头。
改成 `colors.input`（#FFFFFF）+ 既有 hairline 描边 + `↓` 字形。

### 4）空工具行

`RunBuilder` 里结果节点丢了 `callId` 和 `name` 时会落成一个 `title=""`、`summary=""` 的 entry，
真机上就画出一条只有 `✦ 工具调用 ·` 的行（每个调用一条）。
现在 `build()` 丢掉「title / summary / body 全为空」的 entry，`flushRun()` 丢掉空 run。

### 5）设置 `完成`

iOS 实测是白胶囊 + 黑字（x 302.7–389.7、y 60.0–104.7 pt），Android 是裸蓝字。
改成 `colors.input` 胶囊 + `colors.borderLight` hairline + `colors.primary` 字，padding 用既有 `spacing.cardInset`。

### 6）首启首页按 iOS 重建（本轮最大的一处）

`HostHomeScreen` 原来在「读完了、但没有会话」时用 `HomeEmptyState` 顶掉整页：
一张居中卡片「Phone DSH / 运行在手机端的 DeepSeek Harness / 还没有会话 / 新建会话后显示在这里」。
**这张卡是 L62 自己发明的，iOS 的根屏幕是会话列表本身**，所以首启首页没有搜索框、没有新建会话行、
没有工作文件夹、没有「添加工作文件夹」、没有「已归档」——80 % 的帧都画在别的东西上。

改法：删掉空态分支与 `HomeEmptyState`，首页永远渲染同一张 `HostSessionsScreen`
（空态就是这张列表页本身），并把首页自己的纸色从 `colors.selector` 换成 `colors.input`，
否则页头/引导卡的灰底与下面白底页面接出一条通栏接缝。
**L62 的引导卡保留**：Android 真的需要先有 key，iOS 没有这张卡只是因为它的 key 在系统里；
现在它是叠在 iOS 骨架上的一层，而不是取代整页。

效果：同一帧、同一状态，真机 vs iOS **80.06 % → 10.34 %**，真机 vs 并排图 Android 半张 **79.22 % → 8.08 %**。
剩下 10 % 里主要是三块：`未知` 的工作文件夹块（宿主事实缺口，见下）、`已归档 未知`、
以及 iOS 没有而 Android 必须有的 ☰ 页头（抽屉在 Android 上只有这一个入口）。

## registry：6 个「真机上不可达」的状态已标出来

`android/lib/src/androidTest/.../ParityStates.kt` 新增 `ParityStatus.UNREACHABLE("unreachable")`，
并把这 6 个状态从 `CAPTURED` 改过去（样本继续作为页面基线采集，只是不再冒充「真机可达」）：

| 状态 | 为什么真机到不了 |
|---|---|
| `page-sessions-default` | 需要 0 个文件夹这一事实；`HostNavFacts.kt:526` 的 `workspaces = null` |
| `page-sessions-many` | 40 个会话分在 2 个文件夹里，同上 |
| `page-sessions-empty` | 同上（就是 79.22 % 那张） |
| `page-sessions-nothing` | 同上（320 pt 抽屉变体） |
| `page-sessions-ungrouped` | “没有文件夹”本身也是文件夹事实，同上 |
| `page-sessions-schedules` | 宿主不报定时任务快照，真机只画「状态未知 / 未知」，没有「新建任务」 |

`ParityScreenshotTest` / `SessionsParityScreenshotTest` 的 `check(status == CAPTURED)` 改成
`check(status != PENDING)`：样本仍然可以采集，PENDING 仍然拒绝采。
`android/lib/src/test/resources/screenshots/ios-parity/parity-registry.txt` 是**上一次设备采集拉回来的副本**，
它的 status 列还是旧的 `captured`，下一次 parity 采集会重写（本 lane 不能写 `src/test/resources`）。

## PR 用：真机 / 样本 / iOS 三方表（可直接整节引用）

| 状态 | 真机 vs 并排图 Android 半张 | 并排图 Android 半张 vs iOS | 真机 vs iOS |
|---|---|---|---|
| `page-sessions-empty`（首启首页，修前） | **79.22 %** | **6.27 %** | **80.06 %** |
| `page-sessions-empty`（首启首页，修后） | 8.08 % | 6.27 % | **10.34 %** |
| `page-sessions-default`（有会话的列表） | 17.65 % | 13.50 % | 18.27 % |
| `page-chat-default`（聊天） | **87.54 %** | 32.19 % | 78.27 % |
| `page-settings-default`（设置） | 49.90 % | **47.87 %** | **13.70 %** |
| `page-files`（手机工作区） | 10.74 % | 11.93 % | 6.30 % |
| `page-sessions-schedules`（定时任务） | **91.87 %** | 14.02 % | **92.12 %** |

一句话读法：**样本贴着 iOS，真机离两边都远；而设置页反过来——样本比真机更不像 iOS，
所以 DIFFS 把已经对齐的地方判成了缺口。**

## 样本里有、真机没有的控件（逐个）

这是这一轮真正要修的清单。按「样本画了、真机画不出来」列：

| # | 控件 / 结构 | 在哪个状态 | 真机上是什么 | 归属 |
|---|---|---|---|---|
| 1 | 搜索框 `搜索会话` | `page-sessions-empty/default/nothing` 首启首页 | **修前完全没有**；修后有了（首页重建） | 已修 |
| 2 | `+ 新建会话` 行 | 同上 | 修前没有；修后有 | 已修 |
| 3 | 工作文件夹分组（`项目资料` / `设计稿 1`） | sessions 全家族 | `未知` + 「宿主没有报告工作文件夹」 | **宿主不报 facts** |
| 4 | 分组内 `还没有会话 / 点上面的「新建会话」开始。` | `page-sessions-empty` | 不存在（没有分组） | 同上 |
| 5 | `+ 添加工作文件夹` 行 | 修前首启首页 | 修前没有；修后有（点击是诚实拒绝） | 已修 |
| 6 | `> 已归档  0` | 修前首启首页 | 修前没有；修后是 `已归档 未知` | 已修（值仍是未知） |
| 7 | iOS 主按钮 `新建工作文件夹` | `page-sessions-default` | 文字链 `添加工作文件夹`，无主按钮 | 页面（`SessionsPage`） |
| 8 | `新建任务` 主按钮 + 空态两句话 | `page-sessions-schedules` | **完全没有**，只有「状态未知 / 未知」 | 宿主不报快照 |
| 9 | `已调用工具` 折叠组 | `page-chat-default` | 平铺工具行；每调用还多一条空行 | 已修一半（空行去掉，折叠组仍是平铺） |
| 10 | 会话名标题（`新会话` / 会话名） | `page-chat-*` | 修前是 `PDSH`；修后 `当前会话` | 已修 |
| 11 | `↓ 回到最新` 胶囊（箭头 + 近白底） | `page-chat-default` | 修前无箭头、底色=页面灰；修后一致 | 已修 |
| 12 | 恢复会话停在尾部 | 任意 chat 状态 | 修前停在顶部；修后落尾 | 已修 |
| 13 | 思考行（`思考` + 摘要） | `page-chat-official` 等 | 真机恢复的对话里没有思考行 | 宿主投影（未查实） |
| 14 | `完成` 白胶囊 | `page-settings-default` | 修前蓝字无底；修后一致 | 已修 |
| 15 | 字号大小只画 `>` | `page-settings-default` | 多一串 `17 px / 14 px / 13 px` | 未改（信息密度） |
| 16 | 文件页无返回位 | `page-files` | 左上角一个 `‹` | 未改（Android 压栈路由） |

## 验收：`run-product-flow.sh --step 7` 现在过不过

**没过。** 失败句和修前一样，但**原因换了一个**：从「App 停在顶部」变成「脚本要求两条断言在同一屏」。
我没有为了让这一步变绿去改 App 的行为。

```
FAIL 步骤7: 重开原会话后 dump 里没有回答里的 325.21（回答没有持久化）
```

`step_7` 的两条断言对**同一次 dump** 生效（`android/tools/acceptance/run-product-flow.sh:1150-1164`）：

```bash
while [ "$scrolls" -lt 4 ]; do
   if [ -z "${S_PROMPT:-}" ] || ui_has --text "$S_PROMPT"; then break; fi
   adb_c shell input swipe 540 700 540 1600 250   # 手指向下 = 看更早的内容
   ui_dump ...                                    # 每滚一次就覆盖同一份 dump
done
... ! ui_has --text "$S_EXPECTED_TOTAL" → FAIL
```

* 修前：停在顶部 → `S_PROMPT`（第一条消息）一眼可见、不滚 → `325.21`（最后一条回答）在视口外 → FAIL。
* 修后：**停在尾部**（我单独打开同一会话截图证实 `325.21` 在屏上）→ `S_PROMPT` 在视口上方 →
  脚本按设计往上滚去找它 → 第一下就滚到顶（余量 554 px < 一次滑动 900 px）→
  `325.21` 又落到视口外 → **同一个 FAIL 文案**。

也就是说：这段对话在 402×874 pt 框里正文约 **2592 px**，聊天视口约 **2038 px**，
**两条断言只有在整段对话一屏放得下时才可能同时为真**。这次 fixture 是
「11 段流式正文 + 两轮问答 + 工具行」，一屏放不下，所以无论列表停在顶还是停在尾，这个脚本都判 FAIL。

证据：`/tmp/l86/accept/20261102-183449-2285/step7-fail.{xml,png}`（修后那次）里
`acceptance 181756 hello there` 在 y 364、`325.21` 不在 dump；
同一份 APK 上我手动重开同一会话时 `325.21` 在 y 2034–2052（[02-chat-restored-tail.png](02-chat-restored-tail.png)）。

**首页重建后在同一台设备上重跑了一遍全流程**（2026-11-02 18:46，`/tmp/l86/accept2/`）：
**步骤 1–6 全 PASS，步骤 7 仍然同一句 FAIL**，dump 与上面同形（`当前会话` 标题、第一条 prompt 可见、
`325.21` 不在 dump）。也就是说首页重建没有动主流程，步骤 7 的判定与首页无关。

**建议的脚本修法**（`android/tools/acceptance/**` 不在本 lane 可写范围，没有改）：
把 `S_EXPECTED_TOTAL` 的断言放在**滚之前**那份 `step7-reopened.xml` 上（那时在尾部、回答可见），
或者滚到 prompt 之后再向下滚回尾部再断言；也可以给这一步换一条放得下一屏的会话。

## 门禁

```
:lib:testDebugUnitTest :app:assembleDebug           PASS（:lib 752 tests / :app 101 tests）
scripts/ci/check.sh --only phone-android-tests      PASS（2037 tests / 0 failing）
scripts/ci/check.sh --only phone-p0-conformance     PASS（73 tests, 1 known divergence, 0 new）
```

`androidTest` 侧另外编译通过（`./gradlew :lib:compileDebugAndroidTestKotlin`），
因为 registry 的 `UNREACHABLE` 改了 `ParityState` 与两个采集套件的 `check`。

## 还没解决的问题（按用户第一眼看到的顺序）

1. ~~首页首启空态~~ **已修**（本轮 §6，80.06 % → 10.34 %）。剩下的 10 % 主要是
   工作文件夹那一段的 `未知`，见第 2 条；以及 iOS 没有、但 Android 必须有的 ☰ 页头
   （抽屉在 Android 上只有这一个入口，除非给抽屉加边缘滑动）。
2. **工作文件夹永远是 `未知`**：宿主 facts 层不读工作文件夹（`HostNavFacts.kt:526` `workspaces = null`），
   首页与抽屉只能画「未知 / 宿主没有报告工作文件夹」。注册表已把这 5 个 sessions 状态标成
   `unreachable`（见上一节），**但要真机上出现 iOS 的分组，仍然需要宿主补 folder facts** ——
   那是 `HostNavFacts.kt` 与引擎读侧的事，不在本轮可写范围。
3. **定时任务没有主行动**：真机不渲染 `新建任务`，也没有 iOS 的空态两句话；
   `page-sessions-schedules` 已在注册表标 `unreachable`，要真机上出现主按钮仍需宿主报快照。
4. **工具行状态 `已停止`**：结果节点没带 `callId`/`name`，配不上对，被收尾逻辑统一成 STOPPED。
   修点在宿主投影（`ChatSurface.kt`，本 lane 不可写）；UI 侧本轮只做到「不画空行」。
5. **聊天页头 `运行中` 常亮**：这一会话并没有在跑（`运行中` 绿点仍在）。没查实是状态问题还是设计。
6. **输入框占位符被裁**：`发消息或创建任务，/ 调用指令，@ 文件或对话` 在同一帧里 iOS 放得下、
   Android 放不下（墨宽 1006 px 已裁 vs iOS 899 px 完整），是字体栅格差，不是 padding 差；
   要么接受裁切（现在没有省略号），要么只给这一处降一档字级 —— 两条都会偏离基线，本轮没动。
7. **文件页 `‹`**：iOS 这一页没有返回位；Android 是压栈路由，去掉它要另想返回手势，本轮没动。
8. **`字号大小` 的 `17 px / 14 px / 13 px`**：iOS 只画一个 `>`。是信息密度选择，不是对齐问题，未改。
