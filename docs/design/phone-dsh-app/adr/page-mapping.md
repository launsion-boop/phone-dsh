# 页面与预览归属映射（M0）

- 日期：2026-11-03
- 基线：`fe33f75f46e970c051668027d85e9748b8f591ce`
- 原则：DSH 保留执行工作台；发现统一连接器、插件与硬件；个人负责模型、Memory、权限、隐私和数据。新页面的 Android 实现按 ADR-6 登记例外，不伪造同步。

## 1. `spec/ui/v1/pages` 全量映射

| 文件 | 新归属 | 实施责任 |
| --- | --- | --- |
| `chat.json` | DSH 当前会话页，不是 Personal Agent | S1 保留并传 Dock inset |
| `sessions.json` | DSH 会话抽屉/列表 | S1 |
| `workspace-folders.json` | DSH 工作区与文件夹 | S1 |
| `native-workbench.json` | DSH 工作区 | S1 |
| `files.json` | DSH 文件与产物 | S1 |
| `session-artifacts.json` | DSH 产物 | S1 |
| `session-activity.json` | DSH 子 Agent/后台活动 | S1 |
| `native-automation.json` | DSH 定时任务 | S1 |
| `native-device-session.json` | DSH 主动设备会话；Personal Agent 来源化在 M5 | A0，M5 再改 |
| `native-device-connection.json` | 发现 → 硬件 | S1 |
| `native-configuration.json` | 发现 → 插件与运行配置 | S1 |
| `native-plugin-inventory.json` | 发现 → 插件 | S1 |
| `native-agent-presets.json` | DSH 新建会话入口 | S1 |
| `settings.json` | 个人页组合，不再承担全部设置一级入口 | S1 |
| `model-provider-settings.json` | 个人 → 模型与用量 | S1 |
| `model-provider-editor.json` | 个人 → 模型编辑 | S1 |
| `web-search-settings.json` | 发现 → 插件工具配置 | S1 |
| `mcp-settings.json` | 个人 → 权限、隐私与网络 | S1 |
| `mcp-editor.json` | 个人 → MCP 配置 | S1 |
| `egress-allow-list.json` | 个人 → 网络访问 | S1 |
| `phone-permissions.json` | 个人 → 手机权限；设备详情可深链同一状态 | S1 |
| `chat-preferences.json` | 个人 → 对话与显示偏好 | S1 |
| `native-shortcuts.json` | 个人 → 快捷键 | S1 |
| `native-settings-document.json` | 个人 → 设置文档/许可 | S1 |
| `runtime-details.json` | 个人 → 引擎与恢复 | S1 |
| `settings-about.json` | 个人 → 关于 | S1 |
| `memory.json` | 现有内存压力探针，DEBUG；不得作为个人 Memory | S1，个人 Memory 新建 `personal-memory` |
| `daily-brief.json` | 现有能力保留，作为 Chat Artifact，不恢复独立 Tab | S3 |
| `pdsh-shell.json` | DSH 开发者/诊断工具 | S1 |
| `native-workbench.json` | DSH 工作区 | S1 |
| `probes.json` | DEBUG 探针，不进入产品主导航 | S1 |
| `background.json` | DEBUG 后台探针，不进入产品主导航 | S1 |
| `task-screen.json` | DEBUG 长任务屏幕，不进入产品主导航 | S1 |
| `export.json` | DEBUG/个人数据导出，按调用来源进入 | S1 |
| `native-device-session.json` | DSH 主动设备会话，保留到 M5 评审 | A0 |
| `native-device-connection.json` | 发现 → 硬件 | S1 |
| `_baseline.json` | 棘轮基线，只允许减少分歧 | S1 |
| `_whitelist.json` | 结构白名单，按新页面补齐 | S1 |
| `_unrecognized.json` | 未识别页面登记，不用于隐藏新页面 | S1 |
| `_spec-required.json` | 新页面必需契约清单 | S1 |
| `_android-only.json` | Android 例外及后续里程碑 | S1 |
| `_android-only-items.json` | Android 例外条目明细 | S1 |

## 2. `PhoneDSHProbe` 页面级文件归属

| 文件族 | 新归属/责任 |
| --- | --- |
| `RootView.swift`、`NativeShell.swift`、`ChatPage.swift`、`HomeDrawer.swift`、`HomeSpec.swift` | AppShell/DSH 外壳，S1；保留一个 Worker 锚点 |
| `SessionsPage.swift`、`SessionActivityPage.swift`、`SessionArtifactsPage.swift`、`NativeAutomationPage.swift`、`NativeWorkbenchPage.swift`、`FilesPage.swift` | DSH，S1 |
| `SettingsPage.swift`、`ModelProviderSettingsPage.swift`、`WebSearchSettingsPage.swift`、`MCPSettingsPage.swift`、`MCPSettingsModel.swift`、`PhonePermissionsPage.swift`、`ChatPreferencesPage.swift`、`NativeShortcutsPage.swift`、`NativeSettingsDocumentPage.swift`、`ExportPage.swift` | 个人或发现的对应设置，S1 按 §1 迁移 |
| `NativeConfigurationPage.swift`、`NativeConfigurationModel.swift`、`NativePluginInventoryPage.swift`、`NativeAgentPresetsPage.swift`、`PDSHShellPage.swift` | 发现插件/DSH 诊断，S1；presets 到 DSH 新建会话 |
| `MemoryPage.swift` | 内存压力探针，S1 保留 DEBUG；个人 Memory 由 S3 新建 |
| `DailyBriefPage.swift`、`DailyBriefModel.swift` | S3 复用为 Chat Artifact，不新增一级 Tab |
| `NativeDevice*.swift`、`DeviceTranscriptProjection.swift` | DSH 主动设备路径，M5 前冻结 |
| `ComposerVoiceInput.swift` | Personal Agent 与 DSH 可复用的语音输入组件，S3 接 Chat |
| `NativeConversation*.swift`、`NativeMessage*.swift`、`NativeMarkdown*.swift`、`NativeDiff*.swift`、`NativeChat*.swift`、`NativeTool*.swift`、`NativeTurn*.swift`、`NativeQuestion*.swift`、`NativePlan*.swift`、`NativeCode*.swift` | DSH 消息与工具展示组件，S1 保留；Personal Agent 不复用其技术输出 |
| `NativeAskQuestionCard.swift` | DSH 审批/问答组件，S1；Chat 只复用简化问题语义，不复用技术审批卡 |
| `NativeDeviceDependencies.swift` | 设备组合依赖，M5 前冻结 |
| `ProbesPage.swift`、`BackgroundPage.swift`、`BackgroundKeepAlive.swift`、`TaskScreenPage.swift`、`ExportPage.swift`、`AppModel.swift` | DEBUG/生命周期支撑，S1/A0 |
| `PhoneDSHProbeApp.swift` | A0 组合根与 scenePhase，其他 Agent 不改 |
| `AppComposition.swift` | A0 全局唯一组合根 |
| `PersonalAgent/**` | S3 Chat 页面，S2/S4 仅提供协议，不在此处实现 Runtime/门禁 |
| `Shell/**`、`Discover/**`、`Profile/**` | S1 |
| `Discover/Connectors/GitHub/**` | S5 专属配置段 |
| `Discover/Connectors/Gmail/**` | S6 专属配置段 |

## 3. `PreviewScreen` 路由映射

| 旧路由 | 新处理 |
| --- | --- |
| `settings`、`settings.model`、`settings.model.add`、`settings.search`、`settings.network`、`settings.plugins`、`settings.permissions`、`settings.permissions.tab`、`settings.about`、`settings.runtime` | 保留可预览，实际归属按 §1；`settings.plugins` 改到发现，`presets` 预览归 DSH 新建会话 |
| `configuration` | DSH/诊断保持，不改作 Personal Agent |
| `files.preview.*`（text/markdown/html/chat/files/long/pdf/image/office/audio/3d） | DSH 文件预览保持 |
| `sessions`、`sessions.many`、`sessions.empty`、`sessions.nothing`、`sessions.ungrouped`、`sessions.error`、`sessions.schedules` | DSH 会话抽屉与定时任务保持 |
| `workspace`、`workspace.files` | DSH 工作区保持 |
| `chat.assistant`、`chat.official`、`chat.failed`、`chat.queued`、`chat.permission`、`chat.question`、`chat.long`、`chat.draft`、`code.block` | DSH 消息流保持；不得作为 Personal Agent 极简消息流样例 |
| 新增 `app.chat`、`app.dsh`、`app.discover`、`app.profile`、`app.dock`、`personal-memory`、`followup-detail`、`connector-github`、`connector-gmail` | S1 统一新增并接 preview/golden；S3/S5/S6 提供页面结构描述 |

## 4. Android 文件映射与例外

以下 Android 文件保留原实现，不进入本期 iOS 改动；新 iOS 页面另建例外条目，写明后续 Android 里程碑：

- 会话与执行：`ChatPage.kt`、`ChatRows.kt`、`SessionPageChrome.kt`、`SessionTurns.kt`、`SessionHistoryPage.kt`、`SessionsPage.kt`、`SessionActivityPage.kt`、`NativeAutomationPage.kt`、`NativeWorkbenchPage.kt`、`WorkspaceFoldersPage.kt`、`FilesPage.kt`、`WebSurfacePage.kt`、`ToolsPage.kt`、`GoalDetailPage.kt`。
- 设置：`SettingsPage.kt`、`ModelProviderSettingsPage.kt`、`WebSearchSettingsPage.kt`、`MCPSettingsPage.kt`、`MCPEditorPage.kt`、`EgressAllowListPage.kt`、`NativeConfigurationPage.kt`、`AboutPage.kt`。
- 探针与保留能力：`ProbesPage.kt`、`BackgroundPage.kt`、`TaskScreenPage.kt`、`ExportPage.kt`、`RuntimeDetailsPage.kt`、`MemoryPage.kt`、`DailyBriefPage.kt`。
- 共享组件：`UiPageTags.kt`、`PageScaffold.kt`。

Android 例外至少新增：`PersonalAgentChat`、`PersonalMemory`、`FollowUpDetail`、`Discover`、`Profile`、`ConnectorGitHubDetail`、`ConnectorGmailDetail`、`AppDock`。例外表示未实现，不是 PASS。

## 5. 新页面责任

| 新页面 | 责任 |
| --- | --- |
| `AppShell/AppTab/AppDock` | S1 |
| `PersonalAgentChatPage` | S3 |
| `personal-memory` | S3 |
| `FollowUpDetail` | S3 |
| `Discover/Profile` | S1 |
| `ConnectorDetail` 通用结构 | S1 |
| GitHub 配置段 | S5 |
| Gmail 配置段 | S6 |
| `SourceEnvelope/WorkMandate` 展示所需状态 | S4 提供数据，S3 极简呈现 |
