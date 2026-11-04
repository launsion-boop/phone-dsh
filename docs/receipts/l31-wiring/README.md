# L31 — 把「代码在、但用户点不到」的最后几处接线补上

> 范围：`android/app/src/main/kotlin/com/phonedsh/probe/HostNavFacts.kt`、
> `HostShell.kt`、`ProbeEngineViewModel.kt`（各一处宿主读取/入口）、
> `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshNavHost.kt`（**只接线**：删掉一处重复
> apply、补设置页 `tabContent`/聊天菜单两行）、`android/tools/verify-nav-entries.sh`（一个期望
> 字符串 + 一条 Files 入口断言），以及本目录。
> **未改**：`spec/**`、`Sources/**`、`examples/**`、`plugins/**`、`shell/**`、`android/core/**`、
> `android/dsh/**`、`android/engine/**`、`preview/**`、任何**页面实现文件**（`FilesPage.kt`、
> `WorkspaceFoldersPage.kt`、`SettingsPage.kt` …）。**没有任何 git 写操作。**
> 设备：自建 AVD `pdsh-l31`（android-35 / pixel_6 / 1080×2400@420，端口 **5658**，`-no-window`），
> 用完已删。截图见 `screens/`，无障碍树原文见 `*.txt`。

---

## 0. 结论

1. **`workspaceFolders` 现在报一个真实文件夹**：App 自己的那一个工作区
   （`filesDir/xl/materialized/workspace`，`WalPaths.materializedWorkspace`）。
   只有该目录**被量到存在**时才报，行名就是目录自己的名字 `workspace`（页面把它显示成
   「默认文件夹」），会话数保持 `null`（未知）。目录不存在时仍报「无列表（未知）」。
2. **Files 页现在能从 App 走进去**：抽屉新增「文件」行（设备实测，见 §2）。
   但**工作文件夹页那一行仍是死的**——`WorkspaceFoldersPage.kt:623` 把「打开文件列表」的
   `clickable` 绑在 `writable` 上，而本宿主 `writable = NO`。这是页面缺陷（一行修复），
   本车道不改页面，见 §2.3。
3. **`WorkbenchRoute` 的重复 `OpenFile` 已清掉**：一次点击只剩一个 preview（路由 push），
   不再在它背后再投影一个内联 preview。
4. **另外补了同一类接线**（都在 `PdshNavHost.kt`，都是页面已有接缝）：设置五分页的
   `tab`/`onSelectTab`/`tabContent`（模型 / 插件 / 手机权限 / 预设四个 tab 体第一次可达）、
   聊天页头菜单的「运行状态」「本会话设置」两行。见 §3。
5. **全仓「无调用点」清单**见 §4：路由 31 个、页面 39 个，逐个给出「App 里能不能走到 / 该补还是该删」。
6. `:app:assembleDebug` 绿；`:lib:testDebugUnitTest` 全量重跑绿。

---

## 1. `workspaceFolders` 报了什么，为什么这是真的

### 1.1 事实

* `ProbeEngineViewModel.workspaceRoot = File(application.filesDir, "xl")`（`:357`），
  这个 App 的 WAL、journal、exec、host-state 全建在它下面；**本 App 只有一个工作区**。
* 文件页读的是它的物化镜像：`WalPaths.materializedWorkspace = xl/materialized/workspace`，
  也就是 `PreviewWorkspace.defaultRoot(filesDir)`（L29 的 `PreviewFs` 默认根）。
* 设备实测（本车道，5658，引擎起来之后）：

  ```
  $ adb shell run-as com.phonedsh.probe ls -la files/xl/materialized/workspace
  drwx------ 3 u0_a207 u0_a207 4096 ... .
  drwx------ 2 u0_a207 u0_a207 4096 ... notes
  -rw-rw-rw- 1 u0_a207 u0_a207   25 ... notes.txt
  ```

### 1.2 报告规则（`HostNavFacts.kt:293`）

```kotlin
private fun workspaceFoldersFact(present: Boolean): WorkspaceFoldersSnapshot =
    if (!present) WorkspaceFoldersSnapshot(writable = FactState.NO)          // 未知：没量到目录
    else WorkspaceFoldersSnapshot(
        folders = listOf(WorkspaceFolder(
            id = LOCAL_WORKSPACE_NAME,      // "workspace"：物化目录自己的名字
            name = LOCAL_WORKSPACE_NAME,    // 页面 workspaceDisplayName → 「默认文件夹」
            sessionCount = null,            // 没测每文件夹会话数 → 未知
        )),
        writable = FactState.NO,            // 建/切换/删都没有命令
    )
```

`present` 是**宿主在组合根量到的一个文件系统事实**（`ProbeEngineViewModel.kt:608`）：

```kotlin
workspacePresent = Files.isDirectory(walPaths.materializedWorkspace),
```

选这个目录而不是 `xl` 根，是因为**文件页列的就是它**：报的文件夹和点开后看到的树是同一棵。
`PreviewWorkspace.WORKSPACE` 就是这棵树的末段名，所以行名/ id 不是另起的字符串
（`:505`，`const val LOCAL_WORKSPACE_NAME = PreviewWorkspace.WORKSPACE`）。

### 1.3 为什么不是「为了让页面有行」

* 目录不存在时**不报**（返回 `folders = null` → 页面「未知」），而不是报一个不存在的文件夹。
  典型场景：全新安装、引擎还从没恢复过 WAL——那时文件页本来也只能显示「等待引擎连接…」。
* 目录存在但**一个文件都没有**时仍然报：文件夹是真的，只是空的；文件页自己会说
  「还没有文件」。这两件事页面分得很清楚（`FilesPage` 的 waiting / workspaceEmpty 两态）。
* 没有编会话数（`null` → 未知）、没有编「当前文件夹」（`selectedID = null`）、
  没有编一个看不见的 catalog id。
* **这是宿主决策，不是契约替宿主决定**：L29 §1.4 把 id/名字/计数留给了 `:app`；本车道给的是
  「目录名 = id = name」，一条能被磁盘验证的规则。

### 1.4 页面显示成什么

设备实测（`screens/04-workspace-folders.png` + `04-workspace-folders.txt`）：

```
只读：本宿主未实现文件夹的新建、切换、删除
工作文件夹
宿主未提供写命令：本页只读
宿主没有报告的值显示为未知
默认文件夹
未知
[切换]（disabled）  [删除]（disabled）
```

即：一个真实行、名字「默认文件夹」（页面自己的 display rule）、会话数「未知」。
**但这一行点不动**，见下。

---

## 2. Files 页：现在怎么进、为什么抽屉多一行

### 2.1 入口

`HostShell.kt:566`：

```kotlin
PdshDrawerEntry("文件", PdshDrawerIcon.FOLDER, PdshRoute.Files()),
```

抽屉顺序：对话 / 会话 / 工作文件夹 / **文件** / 命令 / 设备连接 / DSH 页面。

为什么不是「让工作文件夹那一行点开」：那一行是基线入口，本车道也把行报出来了，但行被页面自己的
`writable` 开关关掉了（§2.3）。在页面所有者改那一行之前，Files 需要一条**不依赖别的页面状态**的
入口；任务书也点名了这条兜底（「抽屉里直接一条『文件』」）。

### 2.2 设备证据（真 App、真磁盘文件）

AVD 5658，引擎已启动，`files/xl/materialized/workspace` 里放了 `notes/hello.md` 与 `notes.txt`
（25 bytes，`run-as` 写入）：

| 文件 | 证明 |
|---|---|
| `screens/01-drawer.png` | 抽屉里「文件」行（`01-drawer.txt` 有 `desc='文件'`） |
| `screens/02-files-page.png` | 点「文件」→ `手机工作区` 页，列出 `notes/` 与 `notes.txt 25 bytes` |
| `screens/03-preview.png` | 点 `notes.txt` → 预览页显示文件内容 `hello from the workspace`、`已读 25 bytes / 共 25 bytes` |
| `screens/04-workspace-folders.png` | 工作文件夹页：一行「默认文件夹」+ 未知 |

`02-files-page.txt`（无障碍树）：

```
Button ‹ 返回
TextView 手机工作区
TextView 搜索文件
View desc=notes / TextView notes
View desc=notes.txt / TextView 25 bytes
```

### 2.3 已知缺陷：工作文件夹那一行是「死」的（页面侧）

`WorkspaceFoldersPage.kt:620-623`：

```kotlin
Row(modifier = Modifier
    .testTag(UiPageTags.WORKSPACE_ROW)
    .clickable(enabled = writable, role = Role.Button, onClick = { onOpenFiles(folder) })
```

而 `writable` 来自 `FolderRow(writable = state.canWrite)`，`canWrite = snapshot.writable != NO`。
本宿主正确地报 `NO`（不能建/切换/删），于是**「打开文件列表」这个读动作也被一起禁掉**。设备实测
（`04-workspace-folders.txt` 的 clickable 节点）：

```
clickable text=''  desc=''  enabled=false  bounds=[0,463][1080,605]   ← 「默认文件夹」行
clickable text='切换' ... enabled=false
clickable text='删除' ... enabled=false
```

点它：页面不动（实测）。按 `WorkspaceFoldersSnapshot.writable` 的 KDoc（「Whether the host can
create, switch or delete a folder here」），打开文件列表是读、不是写，这一处应当只由
`readable`/路由决定。**建议的一行修复**（不在本车道可写范围）：

```diff
-            .clickable(enabled = writable, role = Role.Button, onClick = { onOpenFiles(folder) })
+            .clickable(role = Role.Button, onClick = { onOpenFiles(folder) })
```

或者给 `FolderRow` 传入 `writable` 仅用于「切换/删除」两个按钮。修好后，Files 页就有两条真实
入口（抽屉 + 工作文件夹行），本车道的抽屉行可以保留也可以作为兜底。

---

## 3. `WorkbenchRoute` 的重复 `OpenFile`

`PdshNavHost.kt:941` 现在只剩：

```kotlin
onOpenFile = { file -> onNavigate(PdshRoute.Preview(file.path)) },
```

旧代码是：

```kotlin
onOpenFile = { file ->
    local = local.apply(WorkbenchUiEvent.OpenFile(file.path))  // ← 删掉
    onNavigate(PdshRoute.Preview(file.path))
}
```

`WorkbenchUiEvent.OpenFile` 会把 `local.previewPath` 置上，`WorkbenchScreenState.from` 据此进入
`isPreviewing` 并画内联 `WorkbenchPreview`。于是**一次点击会有两个 preview**：栈顶是
`PdshRoute.Preview`，它背后还压着一个内联 preview；返回时不是回到文件列表，而是落到内联副本。
现在「一个文件、一个面、一次返回」；`onClosePreview` 保留给「从家页写出行带 `previewPath`
进入 workbench」这一条**不同的**入口（不是这次点击的第二次 apply）。

---

## 4. 另外补的接线（都在 `PdshNavHost.kt`，都是页面已存在的接缝）

### 4.1 设置五分页：`tabContent` 从来没被填过

设置页（`SettingsPage`）有「通用 / 模型 / 插件 / 手机权限 / 预设」五个 tab，并明确声明了
`tab` / `onSelectTab` / `tabContent` 三个宿主接缝；四个非通用 tab 的页面也早就写好了
`embedded: true` 形态。但 `SettingsRoute` 之前**一个都没传**：

* 分段选择器点了没反应（`onSelectTab` 默认 `{}`），
* 四个 tab 体永远不画（`tabContent == null` → `SettingsTabUnavailable`）。

`PdshNavHost.kt:707-745` 现在：

```kotlin
var tab by remember { mutableStateOf(SettingsTab.GENERAL) }
...
tab = tab,
onSelectTab = { selected -> tab = selected },
tabContent = { selected -> when (selected) {
    SettingsTab.GENERAL -> Unit
    SettingsTab.MODELS -> ModelProviderRoute(facts, onBack, onHostAction, embedded = true)
    SettingsTab.PLUGINS -> PluginInventoryRoute(facts, onBack, onNavigate, embedded = true)
    SettingsTab.PERMISSIONS -> PhonePermissionsRoute(onBack = onBack, embedded = true)
    SettingsTab.PRESETS -> AgentPresetsRoute(onBack = onBack, embedded = true)
}},
```

`ModelProviderRoute` 多了一个 `embedded` 参数并透传给页面（页面本来就有 `embedded: Boolean = false`）。

设备实测（5658）：

| 文件 | 证明 |
|---|---|
| `screens/05-settings-models-tab.png` | 「模型」tab → 模型服务页（服务段） |
| `screens/06-settings-plugins-tab.png` | 「插件」tab → 插件配置 / 插件列表；点「插件配置」push 到「本会话设置」 |
| `screens/08-settings-permissions-tab.png` | 「手机权限」tab → 个人信息 / 通讯录… |
| `screens/09-settings-presets-tab.png` | 「预设」tab → 让 Agent 创建预设 + 「宿主还没有返回预设清单…」 |

### 4.2 聊天页头菜单的两行

`ChatRoute` 之前把 `onOpenRunStatus` / `onOpenSessionSettings` 留成页面默认的空回调：菜单里
两行点了只是关菜单。两个目标路由都已经存在且已在别处可达，所以只是两条边：

```kotlin
onOpenRunStatus = { onNavigate(PdshRoute.Runtime) },
onOpenSessionSettings = { onNavigate(PdshRoute.Configuration) },
```

设备实测：`screens/10-chat-run-status.png`（聊天 ⋯ → 运行状态 → 运行时详情）；
「本会话设置」→ 本会话设置 sheet。

---

## 5. 全仓「无调用点」清单（本车道最重要产出）

判定口径：**main 源码**（`:app` + `:lib` 的 `src/main`）里有没有一条从可达页面出发的边；
`src/test` / `src/androidTest` 的调用不算「App 里走得到」。**条件可达** = 边存在但触发条件在真机上
不一定发生。

### 5.1 路由（`PdshRoute`，31 个）

| # | 路由 | App 入口（main） | 状态 |
|---|---|---|---|
| 1 | `Home` | 栈底 / 原生面 | ✅ |
| 2 | `Chat` | 抽屉「对话」 | ✅（页面本身还是空会话桩：无记录、输入坞无回调） |
| 3 | `Sessions` | 抽屉「会话」；Chat 页头 ☰ | ✅（宿主真读 journal） |
| 4 | `WorkspaceFolders` | 抽屉「工作文件夹」 | ✅（行真实；**行点击被页面 `writable` 关掉**） |
| 5 | `Files` | **抽屉「文件」（本车道新增）**；工作文件夹行 | ✅（设备实测） |
| 6 | `Automation` | 抽屉底行「定时任务」 | ✅ |
| 7 | `Configuration` | 原生面 ⋯「本会话设置」；**聊天 ⋯「本会话设置」（新增）**；设置→插件→插件配置 | ✅ |
| 8 | `Settings` | 抽屉底行「设置」 | ✅ |
| 9 | `ModelProvider` | **设置「模型」tab（新增）**；WebSurface 非 live 态「去配置模型服务」 | ✅ |
| 10 | `WebSearch` | 只由「本会话设置 → 网页搜索」行 | ❌ **不可达**：该行只在 `ConfigurationStatus.READY` 画，而宿主 `configuration.snapshot == null` → 状态 UNKNOWN → 行不存在。spec 是 `must`，缺的是宿主读，不是路由 |
| 11 | `Mcp` | 无 | ❌ **不可达**：PR #13 设置改版把「MCP」行删了，spec 现记为 `later/不可达`。**不补入口；保留路由**（页面/契约仍在，且 5.1 之外的预览要用） |
| 12 | `McpEditor` | 只由 `Mcp` 列表 | ❌ 同上（`Mcp` 不可达） |
| 13 | `Egress` | 无 | ❌ **不可达**：设置改版把「网络访问」行删了，spec 记为「预览专用（产品无入口）/later」。**本机 App 自己的出网策略页**——要不要恢复入口是 owner 决定（见 §7） |
| 14 | `Runtime` | 原生面状态点；**聊天 ⋯「运行状态」（新增）** | ✅ |
| 15 | `Workbench` | 原生面回合卡的写出/命令行 | ⚠️ **条件可达**：要先跑出一个带 write/command 的回合。聊天 ⋯「右侧边栏」仍是隐藏的（`onOpenWorkbench` 未接） |
| 16 | `Tools` | 抽屉「命令」 | ✅ |
| 17 | `Export` | 设置附录卡片「导出诊断」 | ✅（页面无导出命令，自己说清楚） |
| 18 | `WebSurface` | 抽屉「DSH 页面」；启动参数 `pdsh.face.web` | ✅ |
| 19 | `DeviceConnection` | 抽屉「设备连接」 | ✅（内存盘演示数据，宿主有 note） |
| 20 | `DeviceSession` | 设备连接行 | ✅（演示传输） |
| 21 | `SessionArtifacts` | 聊天 ⋯「产物」（L25 接的） | ✅（demo 会话 id） |
| 22 | `AgentPresets` | **设置「预设」tab（新增，embedded）** | ✅ 页面可达；**路由本身无 push**（独立路由只为预览/契约，保留） |
| 23 | `PluginInventory` | **设置「插件」tab（新增，embedded）** | ✅ 页面可达；路由本身无 push（同上） |
| 24 | `PhonePermissions` | **设置「手机权限」tab（新增，embedded）** | ✅ 页面可达；路由本身无 push（同上） |
| 25 | `ChatPreferences` | 无 | ❌ 不可达：spec `later/不可达（全仓无调用点）`。**保留、不补** |
| 26 | `SettingsDocument` | 无 | ❌ 不可达：spec `later/不可达`。**保留、不补**（预设页的「查看配置」走页面内错误文案，不跳它） |
| 27 | `Shortcuts` | 「通用」tab 的「快捷键」行 | ❌ **不可达**：行在（`SettingsPage.kt:575`），但 `SettingsRowView` **没有 `destination`** → 点了什么都不发生；`SettingsDestination` 里也没有 `SHORTCUTS`。spec 是 `must`。**必须补，但补在页面侧**（枚举 + 行 destination + `PdshSettingsRows` 映射），见 §7 |
| 28 | `CommandResult` | 无 | ❌ 不可达：基线只在 `executeCommand` 成功后开；本宿主没有命令执行 → 无入口。**保留**（有宿主命令后由宿主 push） |
| 29 | `SessionJobs` | 聊天 ⋯「后台任务（N）」 | ❌ **不可达**：页头菜单行只在 `jobs != null && 非空` 时画，宿主没有 jobs 读（`chatSubpages` 默认 null）→ 行不存在。**不补入口**：补了也只能打开一个「读取不到」的 sheet；等宿主有读时行自然出现 |
| 30 | `SessionSchedules` | 聊天 ⋯「定时任务（N）」 | ❌ 同上 |
| 31 | `Preview` | 文件行；workbench 文件行 | ✅（前者设备实测；后者条件同 `Workbench`） |

另外：`PdshSettingsRows.targetOf` 的 8 个映射里，**6 个没有行会产出**（`MODEL_PROVIDER`、
`WEB_SEARCH`、`MCP`、`EGRESS`、`PLUGIN_CONFIGURATION`、`RUNTIME_DETAILS`；`COMMAND` 也已无行），
实际只剩 `EXPORT_DIAGNOSTICS` 会被调到。这是设置改版后的死映射：**保留**（它是「设置 destination →
路由」的唯一映射表，恢复行时会用到），或者随页面 owner 一起 prune。

### 5.2 `public fun *Page(`（39 个，main 里零调用点的 11 个）

| 页面 | main 调用点 | spec 状态 | 判断 |
|---|---|---|---|
| `AboutPage` | 0（仅测试） | `SettingsAboutPage`：预览专用/later | **保留、不补**（iOS HEAD 没有「关于」入口；Android 设置里只有「当前版本」值行，不是导航行） |
| `BackgroundPage` | 0 | `later`（开发者工具已删，不可达） | 保留（契约页） |
| `DailyBriefPage` | 0 | `later`（基线孤页） | 保留 |
| `MemoryPage` | 0 | `later`（同上） | 保留 |
| `ProbesPage` | 0 | `later`（同上） | 保留 |
| `TaskScreenPage` | 0 | `later`（同上） | 保留 |
| `GoalDetailPage` | 0 | `later`（ChatPage 目标条开） | 保留；聊天页还没有 goal 事实，等宿主读 |
| `SessionActivityPage` | 0 | `later`（sheet 已接线但无人置位） | 保留 |
| `SessionHistoryPage` | 0 | `later`；Android-only 整屏（`_android-only.json`） | 保留；等 `⋯→历史` 入口的宿主 |
| `SessionQueuePage` | 0 | 内嵌子页（随 `SessionsPage` 实现） | **两种选择**：在 `SessionsPage` 里真的嵌它，或删。实测 `SessionsPage` 目前不画队列段（全文件只有 `SessionQueuePage` 自己用 `EditQueueDialog`），宿主也没有队列读 |
| `ToolsPage` | 0（唯一调用者是 `ToolsPageTest`） | `_android-only.json` 明确记为「legacy 命令视图 wrapper，`PDSHShellPage` 才是契约页；**删除顺序：先删 composable + 测试，再删登记**」 | **删**（按登记文件自己写的顺序，页面 owner 执行） |

其余 28 个 `*Page` 都有 ≥1 个 main 调用点（含 `PDSHShellPage` 这类 `internal` 页面，它由
`ToolsRoute` 调）。`PreviewPage` 由 `PreviewRoute` 调，`CommandExecutionResultPage` 由
`CommandResultRoute` 调（路由本身不可达，但页面接线在）。

---

## 6. 验证

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
cd android

./gradlew :app:assembleDebug          # BUILD SUCCESSFUL
./gradlew :lib:testDebugUnitTest --rerun-tasks   # BUILD SUCCESSFUL（全量重跑）
```

设备（`pdsh-l31`，port 5658，`-no-window`，已删）：

```
adb -s emulator-5658 install -r -t app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5658 shell am start -n com.phonedsh.probe/.MainActivity
# 引擎自动跑起来（EngineHostState.Running）后：
#   抽屉 → 文件 → 手机工作区（notes/ + notes.txt 25 bytes）→ notes.txt → 预览内容
#   抽屉 → 工作文件夹 → 默认文件夹（行 enabled=false，实测点不动）
#   抽屉 → 设置 → 模型 / 插件 / 手机权限 / 预设 四个 tab 都能画
#   聊天 → ⋯ → 运行状态 / 本会话设置
```

截图与无障碍树在 `screens/`、`*.txt`。

---

## 7. Open questions

1. **工作文件夹行的 `writable` 门**（§2.3）：应由页面 owner 放开「打开文件列表」这一个读动作
   （一行 diff 已给）。在那之前，本车道的抽屉「文件」行是唯一入口。
2. **`Shortcuts` 的入口**（spec `must`）：需要在 `SettingsPage` 里把「快捷键」行接上
   `SettingsDestination.SHORTCUTS` + `PdshSettingsRows` 映射 + 路由 push。这一处只能页面侧做
   （本车道只被允许动 `PdshNavHost.kt`）；本车道已把「设置 destination → 路由」的映射保留好。
3. **`WebSearch` 的入口**（spec `must`，走 插件 → 插件配置 → 网页搜索）：卡在宿主没有
   configuration 快照（`ConfigurationStatus.UNKNOWN` → 行不画）。要么宿主读配置，要么给一条
   不依赖配置快照的入口——都需要 owner 决定。
4. **`Egress` 要不要恢复入口**：设置改版把「网络访问」行删了（spec 记为「产品无入口/预览专用」），
   但这一页是**本机 App 自己的出网策略**（不是 DSH 设置），删掉入口后用户看不到自己的策略。
   owner 需要决定：恢复设置行（页面侧）还是接受不可达。
5. **`MCP`/`MCPEditor`/`ChatPreferences`/`SettingsDocument`/`SessionJobs`/`SessionSchedules`/
   `CommandResult`**：按 spec/宿主能力保留、不补入口（各自理由见 §5.1）。如果产品要 MCP，
   是恢复设置行还是做成 插件 tab 的第二入口，得先定。
6. **聊天页仍是空会话桩**：「启动本地引擎」「导出对话记录」「右侧边栏」三处仍无宿主回调
   （需要把 `onStart/onStop` 或工作台数据接进 `ChatRoute`，属另一条车道）。
7. **`verify-nav-entries.sh` 的设置段期望已随五分页改版过期**（还去找「模型服务/MCP/网页搜索/网络访问」
   这些已删的行）。本车道只更新了它对本页 note 的期望字符串并加了 Files 入口断言；设置段需要
   页面/设置车道的 owner 一起改（或由下一个动设置的车道统一改）。
8. `SessionsPage` 的 `SessionQueuePage` 是「嵌进去还是删」（§5.2），需要页面 owner 确认队列段
   现在由谁画。
