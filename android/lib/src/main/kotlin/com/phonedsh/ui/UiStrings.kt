// User-visible strings and accessibility labels.
// SPDX-License-Identifier: MIT
//
// These are deliberately *not* tokens: `spec/ui/v1/tokens.json` covers colour,
// type, spacing, radius, stroke, motion and geometry, and the copy is the iOS
// baseline's language (zh). Moving copy to Android string resources
// (`res/values/strings.xml`) is a follow-up: this module may only ship Kotlin
// sources this round, and a resource-less module still has to speak.
package com.phonedsh.ui

/** The copy the UI owns. Tests reference these constants, never a literal. */
public object UiStrings {
    /** Resolves only copy that has an iOS NativeText English pair. */
    public fun settingsNativeText(languageId: String?, chinese: String, english: String): String {
        val useEnglish = when (languageId) {
            "en" -> true
            "zh" -> false
            else -> java.util.Locale.getDefault().language.equals("en", ignoreCase = true)
        }
        return if (useEnglish) english else chinese
    }

    // Chat page
    public const val WAITING_ENGINE: String = "等待引擎连接…"
    public const val WAITING_ENGINE_HINT: String = "引擎就绪后这里显示对话"
    public const val EMPTY_CHAT: String = "还没有消息"
    public const val SESSIONS: String = "会话列表"
    public const val RUNNING: String = "运行中"
    public const val IDLE: String = "空闲"

    // Composer
    public const val COMPOSER_LABEL: String = "输入消息"
    public const val SEND: String = "发送"
    public const val STOP: String = "停止"
    public const val QUEUED: String = "排队中"
    public const val QUEUED_COUNT: String = "排队中 %d 条"
    public const val QUEUED_TAG: String = "已排队"
    public const val STEERED_TAG: String = "已并入当前任务"
    public const val SENDING_TAG: String = "发送中…"

    // Disclosure rows
    public const val EXPANDED: String = "已展开"
    public const val COLLAPSED: String = "已折叠"
    public const val THINKING: String = "思考"
    public const val TOOL_RUNNING: String = "运行中"
    public const val TOOL_OK: String = "完成"
    public const val TOOL_ERROR: String = "失败"
    public const val TOOL_STOPPED: String = "已停止"
    public const val TOOL_NO_DETAIL: String = "没有更多详情"

    // Pending answers
    public const val ALLOW_ONCE: String = "允许一次"
    public const val DENY: String = "拒绝"
    public const val SUBMIT_ANSWER: String = "提交"
    public const val MORE_PENDING: String = "还有 1 个待确认"
    public const val PENDING_SLOT: String = "%d 项需要处理"
    public const val APPROVAL_TITLE: String = "需要授权"
    public const val QUESTION_TITLE: String = "需要回答"

    // Fail-loud
    public const val TURN_FAILED: String = "回合失败"
    public const val SEND_FAILED: String = "发送失败，草稿已保留"
    public const val TOOL_FAILED: String = "工具失败"
    public const val RETRY: String = "重试"
    public const val DISMISS: String = "关闭"
    public const val FAILED_STATUS: String = "失败"

    // Goal bar
    public const val GOAL_PAUSE: String = "暂停"
    public const val GOAL_RESUME: String = "继续"
    public const val GOAL_CLEAR: String = "清除"

    // Files / settings pages
    public const val FILES_EMPTY: String = "工作区还没有文件"
    public const val FILES_EMPTY_HINT: String = "连接引擎后可导入或浏览工作区"
    public const val FILES: String = "工作文件夹"
    public const val IMPORT: String = "导入"
    public const val SETTINGS: String = "设置"
    public const val SETTINGS_EMPTY: String = "没有可显示的设置项"
    public const val MORE: String = "更多"
    public const val BACK: String = "返回"

    // Session list (`spec/ui/v1/README.md` §1 SessionsPage)
    public const val SESSIONS_EMPTY: String = "还没有会话"
    public const val SESSIONS_EMPTY_HINT: String = "新建会话后显示在这里"
    public const val SESSIONS_NO_MATCH: String = "没有匹配的会话"
    public const val SESSION_NEW: String = "新建会话"
    public const val SESSION_SEARCH: String = "搜索会话"
    public const val SESSION_RENAME: String = "重命名"
    public const val SESSION_DELETE: String = "删除"
    public const val SESSION_RENAME_TITLE: String = "重命名会话"
    public const val SESSION_NAME: String = "会话名称"
    public const val SESSION_DELETE_CONFIRM: String = "删除这个会话？"
    public const val SESSION_DELETE_DETAIL: String = "删除后无法恢复"
    public const val SESSION_LOAD_FAILED: String = "会话列表加载失败"
    public const val NEW_SESSION: String = "新会话"
    public const val NEW_SESSION_INDEXED: String = "新会话 %d"
    public const val SAVE: String = "保存"
    public const val CANCEL: String = "取消"
    public const val WAITING: String = "等待"
    public const val JUST_NOW: String = "刚刚"
    public const val MINUTES_AGO: String = "%d 分钟前"
    public const val HOURS_AGO: String = "%d 小时前"
    public const val MONTH_DAY: String = "%d月%d日"

    // One session's turn history (ScreenState layer; no §1 page row yet)
    public const val HISTORY_TITLE: String = "历史回合"
    public const val HISTORY_EMPTY: String = "这个会话还没有回合"
    public const val HISTORY_EMPTY_HINT: String = "有回合后显示在这里"
    public const val HISTORY_DETAIL_EMPTY: String = "这个回合还没有可显示的内容"
    public const val HISTORY_LOAD_FAILED: String = "历史读取失败"
    public const val HISTORY_DETAIL_TITLE: String = "回合详情"
    public const val HISTORY_BACK_TO_LIST: String = "返回列表"
    public const val TURN_LABEL: String = "第 %d 回合"
    public const val TURN_OPEN: String = "进行中"
    public const val TURN_COMPLETED: String = "已完成"
    public const val TURN_CANCELLED: String = "已取消"
    public const val TURN_COUNTS: String = "%d 条消息 · %d 次工具"
    public const val TURN_PENDING: String = "%d 项待确认"

    // One session's activity (`spec/ui/v1/README.md` §1 SessionActivityPage, P5 `later`)
    public const val ACTIVITY_TITLE: String = "会话活动"
    public const val ACTIVITY_STEPS: String = "步骤"
    public const val ACTIVITY_USAGE: String = "用量"
    public const val ACTIVITY_CONTEXT: String = "上下文"
    public const val ACTIVITY_EMPTY: String = "还没有可显示的活动"
    public const val ACTIVITY_STEPS_EMPTY: String = "这个会话还没有步骤"
    public const val ACTIVITY_LOAD_FAILED: String = "活动读取失败"
    public const val ACTIVITY_ROUNDS: String = "回合"
    public const val ACTIVITY_TOOLS: String = "工具调用"
    public const val ACTIVITY_FAILURES: String = "失败"
    public const val ACTIVITY_TOKENS: String = "上下文用量"
    public const val ACTIVITY_WORKSPACE: String = "工作文件夹"
    public const val ACTIVITY_SESSION: String = "会话"

    // Goal bar (§3) and the goal detail sheet (no §1 page row)
    public const val GOAL_TITLE: String = "目标"
    public const val GOAL_ACTIVE: String = "进行中"
    public const val GOAL_PAUSED: String = "已暂停"
    public const val GOAL_BLOCKED: String = "受阻"
    public const val GOAL_COMPLETE: String = "已完成"
    public const val GOAL_EMPTY: String = "这个会话没有目标"
    public const val GOAL_ROUNDS: String = "%d / %d 轮"
    public const val GOAL_BLOCKED_REASON: String = "原因"
    public const val GOAL_READ_FAILED: String = "目标读取失败，沿用上次结果"
    public const val GOAL_DETAIL: String = "目标详情"
    public const val GOAL_LOAD_FAILED: String = "目标读取失败"

    // ---------------------------------------------------------------------
    // Settings / tools / files / memory / about (P5 K2 lane)
    // ---------------------------------------------------------------------

    // Three-valued facts. `UNKNOWN` is a real answer, never a placeholder for a
    // default: the pages must not invent an unmeasured value.
    public const val UNKNOWN: String = "未知"
    public const val UNAVAILABLE: String = "不可用"

    // Settings: group chrome and the platform-divergence rows the page owns
    // (`spec/platform/whitelist.json` rows `platform.post-notifications-degraded`,
    // `platform.battery-exemption-policy`, `platform.predictive-back`).
    public const val ROW_COUNT: String = "%d 项"
    public const val SETTINGS_PLATFORM: String = "平台差异"
    public const val SETTINGS_UNKNOWN_HINT: String = "读取不到这项状态，未做任何假设"

    /**
     * The one line a page prints when the host reported that its actions cannot
     * be written here (`FactState.NO` in the page's `writable` fact). The control
     * itself is rendered disabled next to this line, so the reason is visible
     * before the person tries it rather than after.
     */
    public const val HOST_READ_ONLY_HINT: String = "宿主未提供写命令：本页只读"

    /** The MCP editor's handoff note: the save is submitted, not persisted here. */
    public const val MCP_EDITOR_HANDOFF_HINT: String = "保存会提交给宿主；本宿主未实现持久化"
    public const val SETTINGS_NOTIFICATIONS: String = "通知权限"
    public const val SETTINGS_NOTIFICATIONS_ON: String = "已开启"
    public const val SETTINGS_NOTIFICATIONS_ON_HINT: String = "前台服务通知可见，后台回合能显示进度"
    public const val SETTINGS_NOTIFICATIONS_DEGRADED: String = "降级"
    public const val SETTINGS_NOTIFICATIONS_DEGRADED_HINT: String =
        "通知不可见：后台回合降级为仅前台，被杀或中断的下次打开时报告"
    public const val SETTINGS_NOTE_NOTIFICATIONS: String = "通知权限被拒：后台回合降级为仅前台"
    public const val SETTINGS_BATTERY: String = "电池优化"
    public const val SETTINGS_BATTERY_EXEMPT: String = "已豁免"
    public const val SETTINGS_BATTERY_EXEMPT_HINT: String = "后台回合不受电池优化限制"
    public const val SETTINGS_BATTERY_NOT_EXEMPT: String = "未豁免"
    public const val SETTINGS_BATTERY_NOT_EXEMPT_HINT: String =
        "后台回合可能被系统中断；分发政策只引导用户关闭，不申请豁免"
    public const val SETTINGS_NOTE_BATTERY: String = "电池优化未豁免：后台回合可能被系统回收"
    public const val SETTINGS_BACK: String = "返回手势"
    public const val SETTINGS_BACK_PREDICTIVE: String = "系统预测性返回"
    public const val SETTINGS_BACK_PREDICTIVE_HINT: String = "返回由系统手势承载，页面栈逐级出栈"
    public const val SETTINGS_BACK_NOT_ENABLED: String = "未启用"
    public const val SETTINGS_BACK_NOT_ENABLED_HINT: String = "返回按系统默认处理"

    // ---------------------------------------------------------------------
    // N4 lane: the iOS SettingsPage index, row for row
    // (`examples/probe-app/PhoneDSHProbe/SettingsPage.swift`). Every literal
    // below is the Swift literal, not a paraphrase: the index shows these exact
    // words, and `SettingsPage.kt` claims no value it did not receive.
    // ---------------------------------------------------------------------

    // The one group title the mirrored page adds; the first group has none.
    public const val SETTINGS_GROUP_TOOLS: String = "工具"

    // The baseline sheet's only chrome action.
    public const val SETTINGS_DONE: String = "完成"

    // Row labels, in the order the baseline renders them.
    public const val SETTINGS_ROW_PERMISSION: String = "权限"
    public const val SETTINGS_ROW_ASK_BEFORE_WRITE: String = "写之前"
    public const val SETTINGS_ROW_MODEL_SERVICE: String = "模型服务"
    public const val SETTINGS_ROW_MCP: String = "MCP"
    // 蓝牙设备 (BluetoothDevicesPage.swift:46, :111): count and profile templates.
    public const val BLE_SHOW_OTHER_DEVICES: String = "展开其他设备（%d 个，未发现设备能力）"
    public const val BLE_READ_PROFILE: String = "读取 %s"
    public const val SETTINGS_ROW_BACKGROUND: String = "后台运行"
    public const val SETTINGS_ROW_NETWORK: String = "网络访问"
    public const val SETTINGS_ROW_PLUGINS: String = "插件与模型"
    public const val SETTINGS_ROW_SEND: String = "发送消息时"
    public const val SETTINGS_ROW_EXPORT: String = "导出诊断"

    // The iOS list names SwiftTerm/swift-nio, which this app does not ship. The
    // Android build distributes AndroidX/Compose, Kotlin and kotlinx instead.
    public const val SETTINGS_LICENSES_ANDROID_ONLY: String =
        "Android 分发 AndroidX / Jetpack Compose、Kotlin、kotlinx.coroutines 与 Ktor；不含 iOS 的 SwiftTerm / swift-nio。"

    // The permission pair. 未设置 is the baseline's wording for a tier it cannot name.
    public const val SETTINGS_PERMISSION_UNSET: String = "未设置"
    public const val SETTINGS_ASK_NO_MORE: String = "不再问"
    public const val SETTINGS_ASK_EVERY_TIME: String = "每次都问"

    // The 后台运行 positions. iOS draws a UISwitch; the port's rows state their
    // position in words, so an unread switch is 未知 instead of "off".
    public const val SETTINGS_BACKGROUND_ON: String = "已开启"
    public const val SETTINGS_BACKGROUND_OFF: String = "已关闭"

    // MCP: the baseline prints 未配置 both when the engine is not up and when
    // there is no server, and the count only when there is at least one.
    public const val SETTINGS_MCP_SERVER_COUNT: String = "%d 个服务器"

    // The tools footer: one line, three possible sources, this precedence.
    public const val SETTINGS_FOOTER_RESTART: String = "重启本地引擎后生效。"
    public const val SETTINGS_FOOTER_SAVED: String = "已保存。"

    // The 网页搜索 row's summaries: the baseline's three branches.
    public const val SEARCH_SUMMARY_FOLLOW_MODEL: String = "沿用模型服务"
    public const val SEARCH_SUMMARY_SEARCH_API: String = "独立 DeepSeek 搜索 API"
    public const val SEARCH_SUMMARY_UNREADABLE: String = "网页搜索配置不可读"

    // The 发送消息时 picker's two entries.
    public const val BUSY_ENTER_QUEUE: String = "排到下一轮"
    public const val BUSY_ENTER_STEER: String = "补充当前任务"

    // The 权限 row's sub-page (the baseline's PermissionDefaultsPage): its title,
    // its scope sentence, and the three presets in menu order.
    public const val PERMISSION_DEFAULTS_TITLE: String = "新会话默认权限"
    public const val PERMISSION_DEFAULTS_NOTE: String = "只影响之后新开的会话，当前会话保持不变。"
    public const val PERMISSION_TIER_VIEW_ONLY: String = "仅可查看"
    public const val PERMISSION_TIER_WORKSPACE_WRITE: String = "工作区内修改"
    public const val PERMISSION_TIER_FULL_ACCESS: String = "完全权限"
    // The phone image's home patch pins permission.defaultPreset from
    // PDSH_SANDBOX_MODE. The provider's global writable flag does not grant a
    // write through that startup overlay, so the selector is read-only and says
    // exactly which layer owns the value, what makes it writable, and that the
    // running conversation keeps its permission.
    public const val DEFAULT_PERMISSION_STARTUP_LOCKED_REASON: String =
        "只读：新会话默认权限由启动配置（home patch / PDSH_SANDBOX_MODE）锁定，优先于可编辑设置。请修改启动配置并重启本地引擎；现有会话的权限不受影响。"
    public const val DEFAULT_PERMISSION_STARTUP_LOCKED_REASON_EN: String =
        "Read only: the startup configuration (home patch / PDSH_SANDBOX_MODE) locks the default permission for new sessions above editable settings. Change the startup configuration and restart the local engine; existing sessions keep their permission."
    public const val DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON: String =
        "只读：引擎没有报告这一项可写。请在启动配置中修改并重启本地引擎；现有会话的权限不受影响。"
    public const val DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON_EN: String =
        "Read only: the engine does not report this setting as writable. Change the startup configuration and restart the local engine; existing sessions keep their permission."

    // Tools (`PDSHShellPage`: the read-only accelerators advertised in the caps)
    public const val TOOLS: String = "命令"
    public const val TOOLS_EMPTY: String = "没有可显示的工具"
    public const val TOOLS_EMPTY_HINT: String = "引擎声明只读加速器后这里显示工具列表"
    public const val TOOLS_AVAILABLE: String = "可用"
    public const val TOOL_AVAILABILITY: String = "是否可用"
    public const val TOOL_ACCELERATOR: String = "加速器名"
    public const val TOOL_ACCELERATOR_NONE: String = "未声明"
    public const val TOOL_COMMAND: String = "命令名"
    public const val TOOL_DESCRIPTION: String = "说明"
    public const val TOOL_READ_ONLY: String = "只读加速器：只读工作区，不写文件"

    // Files: directory browsing and the preview degradations
    public const val FILES_UP: String = "上一级"
    public const val FILES_EMPTY_DIR: String = "这个文件夹是空的"
    public const val FILES_PREVIEW_LOADING: String = "正在读取…"
    public const val FILES_PREVIEW_BINARY: String = "无法预览二进制文件"
    public const val FILES_PREVIEW_BINARY_HINT: String = "按二进制处理，不显示内容"
    public const val FILES_PREVIEW_UNAVAILABLE: String = "无法读取这个文件"
    public const val FILES_PREVIEW_REASON_UNKNOWN: String = "原因未知"
    public const val FILES_PREVIEW_TRUNCATED: String = "内容已截断"

    // Memory: entries by source, plus the measured budget/quota
    public const val MEMORY: String = "记忆"
    public const val MEMORY_EMPTY: String = "还没有记忆条目"
    public const val MEMORY_EMPTY_HINT: String = "记忆写入后会在这里按来源列出"
    public const val MEMORY_BUDGET: String = "内存与配额"
    public const val MEMORY_TIER: String = "内存档位"
    public const val MEMORY_USED: String = "已用"
    public const val MEMORY_QUOTA: String = "配额"
    public const val MEMORY_OVER_QUOTA: String = "已超出配额"
    public const val MEMORY_SOURCE_UNKNOWN: String = "来源未知"
    public const val MEMORY_ENTRY_COUNT: String = "%d 条"

    // ---------------------------------------------------------------------
    // N4 lane: the iOS MemoryPage probe, card for card
    // (`examples/probe-app/PhoneDSHProbe/MemoryPage.swift`). That page is the
    // DEBUG memory-pressure harness, not a memory-entries list; its copy is
    // English in the baseline and is kept verbatim here.
    // ---------------------------------------------------------------------
    public const val MEMORY_PROBE_TITLE: String = "Memory"
    public const val MEMORY_CANCEL: String = "Cancel"

    // The announced form of "a run is in flight" (the baseline's ProgressView).
    public const val MEMORY_RUNNING_LABEL: String = "Running"

    // Card 1: the packed Worker bundle and the lockdown badge.
    public const val MEMORY_SECTION_BUNDLE: String = "Worker bundle"
    public const val MEMORY_BUNDLE_KEY: String = "Bundle/worker"
    public const val MEMORY_BUNDLE_INSTALLED: String = "installed"
    public const val MEMORY_BUNDLE_REFRESH_NOTE: String =
        "Run scripts/copy-bundle-assets.sh to refresh it from plugins/scripts/pack-image.mjs output."
    public const val MEMORY_BUNDLE_MISSING_NOTE: String =
        "The Memory and Background pages need the packed Worker image. " +
            "The Probes page does not; it runs with the probe fixtures only."
    public const val MEMORY_LOCKDOWN_ON: String = "Lockdown Mode ON — local harness unavailable"
    public const val MEMORY_LOCKDOWN_OFF: String = "Lockdown Mode off"

    // Card 2: the overlay levels and the long scripted session.
    public const val MEMORY_SECTION_OVERLAY: String = "Overlay levels"
    public const val MEMORY_RUN_OVERLAY: String = "Run %d MB overlay"
    public const val MEMORY_RUN_LONG: String = "Run long scripted session (no overlay)"
    public const val MEMORY_OVERLAY_NOTE: String =
        "One level boots the host twice: the first boot creates the workspace manifest, " +
            "then the synthetic overlay is seeded and the host boots again. Keep this page open while it runs."

    // Card 3: the phase the runner reports.
    public const val MEMORY_SECTION_PROGRESS: String = "Progress"
    public const val MEMORY_KEY_PHASE: String = "phase"
    public const val MEMORY_KEY_LAST_RUN: String = "last run"

    // Card 4: the samples, newest last, at most eight of them.
    public const val MEMORY_SECTION_LIVE: String = "Live samples"
    public const val MEMORY_LIVE_EMPTY: String =
        "No sample yet. A run records one sample at the start and one per scripted stage."
    public const val MEMORY_LIVE_NOTE: String =
        "Proxy metrics only: the App-process phys_footprint and os_proc_available_memory; " +
            "WebContent is a separate process."
    public const val MEMORY_SAMPLE_KEY: String = "t+%ds"
    public const val MEMORY_SAMPLE_VALUE: String = "%s · avail %s · %s"

    // Card 5: the measured levels.
    public const val MEMORY_SECTION_MEASURED: String = "Measured levels"
    public const val MEMORY_KEY_LEVELS: String = "levels"
    public const val MEMORY_LEVEL_MB: String = "%d MB"
    public const val MEMORY_KEY_BOOT: String = "boot"
    public const val MEMORY_KEY_DURATION: String = "duration"
    public const val MEMORY_KEY_WEBCONTENT: String = "WebContent terminations"
    public const val MEMORY_KEY_PEAK: String = "peak footprint"
    public const val MEMORY_KEY_MIN_AVAILABLE: String = "min available"
    public const val MEMORY_KEY_SAMPLES: String = "samples"

    // Card 6: the scripted session.
    public const val MEMORY_SECTION_SESSION: String = "Session"
    public const val MEMORY_KEY_STATUS: String = "status"
    public const val MEMORY_KEY_PLANNED_RESTARTS: String = "planned restarts"
    public const val MEMORY_SESSION_EMPTY: String =
        "Empty until a Memory run records the scripted session. The probe App ships no model upstream, " +
            "so this session exercises lifecycle and overlay reloads, not model turns."

    // The baseline's own glyph for a value its formatter could not produce.
    public const val MEMORY_UNSET_DASH: String = "—"

    // About: version, platform, licenses, the DEBUG-only developer entry
    public const val ABOUT: String = "关于"
    public const val ABOUT_SECTION_VERSION: String = "版本"
    public const val ABOUT_SECTION_SYSTEM: String = "系统"
    public const val ABOUT_SECTION_MORE: String = "更多"
    public const val ABOUT_VERSION: String = "版本号"
    public const val ABOUT_BUILD: String = "构建号"
    public const val ABOUT_ANDROID: String = "Android"
    public const val ABOUT_API_LEVEL: String = "API 级别"
    public const val ABOUT_ABI: String = "ABI"
    public const val ABOUT_DEVICE: String = "设备"
    public const val ABOUT_WEBVIEW: String = "WebView"
    public const val ABOUT_LICENSES: String = "开源许可"
    public const val ABOUT_DEVELOPER: String = "开发者选项"

    // ---------------------------------------------------------------------
    // Q2 lane: the in-session workbench and the workspace folder page
    // (`spec/ui/v1/README.md` §1 `NativeWorkbenchPage` / `WorkspaceFoldersPage`)
    // ---------------------------------------------------------------------

    // NativeWorkbenchPage: the turn's written files and the commands it ran.
    public const val WORKBENCH_TITLE: String = "工作区"
    public const val WORKBENCH_DONE: String = "完成"
    public const val WORKBENCH_FILES: String = "文件"
    public const val WORKBENCH_COMMANDS: String = "命令"
    public const val WORKBENCH_FILES_EMPTY: String = "本次回合还没有写出文件"
    public const val WORKBENCH_FILES_EMPTY_HINT: String = "工具写出文件后显示在这里"
    public const val WORKBENCH_COMMANDS_EMPTY: String = "本次回合还没有执行命令"
    public const val WORKBENCH_COMMANDS_EMPTY_HINT: String = "工具执行命令后显示在这里"
    public const val WORKBENCH_FILES_UNKNOWN_HINT: String = "宿主没有报告本次回合写出的文件，无法判断有没有"
    public const val WORKBENCH_COMMANDS_UNKNOWN_HINT: String = "宿主没有报告本次回合执行的命令，无法判断有没有"
    public const val WORKBENCH_FAILED: String = "工作面板读取失败"
    public const val WORKBENCH_WRITTEN_BY: String = "写入工具 %s"
    public const val WORKBENCH_EXIT_CODE: String = "退出码 %s"
    public const val WORKBENCH_UNMEASURED_HINT: String = "宿主没有报告的值显示为未知"
    public const val WORKBENCH_PREVIEW_PENDING: String = "这个文件还没出现在列表里"
    public const val WORKBENCH_PREVIEW_PENDING_HINT: String = "工具写入后会自动打开；稍后重试"

    // WorkspaceFoldersPage: the folders, their current selection and removal.
    public const val WORKSPACE_FOLDERS: String = "工作文件夹"
    public const val WORKSPACE_EMPTY: String = "还没有工作文件夹"
    public const val WORKSPACE_EMPTY_HINT: String = "会话把生成的文件放在文件夹里。新建一个文件夹给它用。"
    public const val WORKSPACE_UNKNOWN_HINT: String = "宿主没有报告工作文件夹，无法判断有没有"
    public const val WORKSPACE_LOAD_FAILED: String = "工作文件夹读取失败"
    public const val WORKSPACE_NEW: String = "新建文件夹"
    public const val WORKSPACE_NAME: String = "文件夹名称"
    public const val WORKSPACE_CREATE: String = "创建"
    public const val WORKSPACE_NAME_EMPTY: String = "名字不能为空"
    public const val WORKSPACE_NAME_SEPARATOR: String = "名字不能包含 / 或 \\"
    public const val WORKSPACE_NAME_CONTROL: String = "名字不能包含换行等控制字符"
    public const val WORKSPACE_NAME_TOO_LONG: String = "名字不超过 %d 个字符"
    public const val WORKSPACE_CURRENT: String = "当前"
    public const val WORKSPACE_SWITCH: String = "切换"
    public const val WORKSPACE_DELETE: String = "删除"
    public const val WORKSPACE_SELECTED_LOCKED: String = "当前文件夹不能删除"
    public const val WORKSPACE_DELETE_CONFIRM: String = "删除这个文件夹？"
    public const val WORKSPACE_DELETE_DETAIL: String = "里面的会话会留着，只是不再放在这个文件夹里"
    public const val WORKSPACE_SESSION_COUNT: String = "%d 个会话"
    public const val WORKSPACE_DEFAULT_NAME: String = "默认文件夹"
    public const val WORKSPACE_UNMEASURED_HINT: String = "宿主没有报告的值显示为未知"

    // ---------------------------------------------------------------------
    // P5 settings family (Q3 lane): model provider, web search, MCP list/editor.
    // Appended only: the entries above belong to other lanes and are never
    // rewritten. CONFIGURED/NOT_CONFIGURED/SELECTED are shared by more than one
    // page, which is why they carry no page prefix.
    // ---------------------------------------------------------------------
    public const val CONFIGURED: String = "已配置"
    public const val NOT_CONFIGURED: String = "未配置"
    public const val SELECTED: String = "已选"

    // Model provider: one key state per service, never the key.
    public const val MODEL_PROVIDER_TITLE: String = "模型服务"
    public const val PROVIDER_ADD: String = "添加"
    public const val PROVIDER_EMPTY: String = "还没有配置模型服务"
    public const val PROVIDER_EMPTY_HINT: String = "添加一个服务并填入密钥，引擎才能发起请求"
    public const val PROVIDER_UNKNOWN_STATE: String = "模型服务状态未知"
    public const val PROVIDER_UNKNOWN_HINT: String = "读取不到模型服务配置，未做任何假设"
    public const val PROVIDER_SERVICES: String = "服务"
    public const val PROVIDER_HELP: String = "说明"
    public const val PROVIDER_DEFAULT: String = "默认"
    public const val PROVIDER_KEY_INVALID: String = "配置无效"
    public const val PROVIDER_KEY_NOT_CONFIGURED_HINT: String = "还没有保存密钥；填入密钥后才能使用这个服务"
    public const val PROVIDER_KEY_CONFIGURED_HINT: String = "密钥已保存在这台设备上，界面只显示后四位"
    public const val PROVIDER_KEY_INVALID_HINT: String = "密钥或服务配置无效，请重新填写"
    public const val PROVIDER_KEY_SUFFIX: String = "密钥后四位 %s"
    public const val PROVIDER_MODEL: String = "模型 %s"
    public const val PROVIDER_ENDPOINT: String = "服务 %s"
    public const val PROVIDER_FAILURE_CONFIG: String = "读取不到模型服务配置"
    public const val PROVIDER_FAILURE_KEY: String = "读取不到这台设备上的密钥"
    public const val PROVIDER_FAILURE_UNKNOWN: String = "模型服务读取失败"
    public const val PROVIDER_PRIVACY: String = "密钥不会写进配置、日志或页面文本里，界面最多显示后四位"
    public const val PROVIDER_EFFECT: String = "配置从下一次启动 App 起生效"

    // Web search: the switch, the backend choice, and why a switch is held.
    public const val WEB_SEARCH_TITLE: String = "网页搜索"
    public const val WEB_SEARCH_ON: String = "已开启"
    public const val WEB_SEARCH_OFF: String = "已关闭"
    public const val WEB_SEARCH_BACKENDS: String = "搜索后端"
    public const val WEB_SEARCH_EMPTY: String = "还没有可用的搜索后端"
    public const val WEB_SEARCH_EMPTY_HINT: String = "配置一个搜索后端后，网页搜索开关才可用"
    public const val WEB_SEARCH_UNKNOWN_STATE: String = "网页搜索状态未知"
    public const val WEB_SEARCH_UNKNOWN_HINT: String = "读取不到网页搜索配置，未做任何假设"
    public const val WEB_SEARCH_REASON_NO_BACKENDS: String = "未配置搜索后端：开关已禁用"
    public const val WEB_SEARCH_REASON_NO_SELECTION: String = "还没有选择搜索后端：先在下面选一个"
    public const val WEB_SEARCH_REASON_BACKEND_UNCONFIGURED: String = "选中的搜索后端未配置：补全配置后才能开启"
    public const val WEB_SEARCH_REASON_BACKEND_UNKNOWN: String = "读取不到搜索后端状态：先刷新再试"
    public const val WEB_SEARCH_REASON_TOGGLE_UNKNOWN: String = "读取不到开关状态：先刷新再切换"
    public const val WEB_SEARCH_SELECT: String = "选择"
    public const val WEB_SEARCH_BACKEND_CONFIGURED_HINT: String = "已配置，可用于网页搜索"
    public const val WEB_SEARCH_BACKEND_UNCONFIGURED_HINT: String = "未配置：先补全这个后端的配置"
    public const val WEB_SEARCH_FAILURE_CONFIG: String = "读取不到网页搜索配置"
    public const val WEB_SEARCH_FAILURE_BACKENDS: String = "读取不到搜索后端列表"
    public const val WEB_SEARCH_FAILURE_UNKNOWN: String = "网页搜索读取失败"

    // MCP list: name, connection, and the measured (or unknown) tool count.
    public const val MCP_TITLE: String = "MCP 服务器"
    public const val MCP_ADD: String = "添加"
    public const val MCP_SERVERS: String = "服务器"
    public const val MCP_EMPTY: String = "还没有 MCP 服务器"
    public const val MCP_EMPTY_HINT: String = "添加一个服务器后，它的工具会出现在对话里"
    public const val MCP_UNKNOWN_STATE: String = "MCP 服务器状态未知"
    public const val MCP_UNKNOWN_HINT: String = "读取不到 MCP 服务器列表，未做任何假设"
    public const val MCP_CONNECTED: String = "已连接"
    public const val MCP_CONNECTING: String = "连接中"
    public const val MCP_DISCONNECTED: String = "未连接"
    public const val MCP_TOOLS: String = "工具 %d 个"
    public const val MCP_TOOLS_UNKNOWN: String = "工具数未知"
    public const val MCP_FAILURE_REGISTRY: String = "读取不到 MCP 服务器列表"
    public const val MCP_FAILURE_HOST: String = "主机尚未启动，读取不到 MCP 服务器"
    public const val MCP_FAILURE_UNKNOWN: String = "MCP 服务器读取失败"

    // MCP editor: transport, command/URL, enable, and the in-place field errors.
    public const val MCP_EDITOR_NEW: String = "添加 MCP 服务器"
    public const val MCP_EDITOR_EDIT: String = "编辑 MCP 服务器"
    public const val MCP_TRANSPORT: String = "传输方式"
    public const val MCP_TRANSPORT_STDIO: String = "本地命令"
    public const val MCP_TRANSPORT_HTTP: String = "网络地址"
    // 本地命令 / 网络地址 are Android's own two transports (the baseline is HTTP
    // only); each row carries one line saying what choosing it means, so the
    // choice needs no group caption of its own.
    public const val MCP_TRANSPORT_STDIO_HINT: String = "宿主直接在这台手机上启动这个命令"
    public const val MCP_TRANSPORT_HTTP_HINT: String = "宿主连接一个 http 或 https 地址"
    public const val MCP_FIELD_NAME: String = "名称"
    public const val MCP_FIELD_NAME_PLACEHOLDER: String = "A-Z a-z 0-9 _ -"
    public const val MCP_FIELD_NAME_HINT: String = "用于在列表和对话里识别这个服务器"
    public const val MCP_FIELD_COMMAND: String = "命令"
    public const val MCP_FIELD_COMMAND_PLACEHOLDER: String = "启动这个服务器要执行的命令"
    public const val MCP_FIELD_COMMAND_HINT: String = "命令由宿主执行"
    public const val MCP_FIELD_URL: String = "地址"
    public const val MCP_FIELD_URL_PLACEHOLDER: String = "以 http 或 https 开头"
    public const val MCP_FIELD_URL_HINT: String = "地址只用于连接；界面不会显示已保存的地址"
    public const val MCP_FIELD_ENABLED: String = "启用"
    public const val MCP_ENABLED_ON: String = "已启用"
    public const val MCP_ENABLED_OFF: String = "已停用"
    public const val MCP_SAVE: String = "保存"
    public const val MCP_SAVE_CONNECT: String = "保存并连接"
    public const val MCP_SAVE_RECONNECT: String = "保存修改并重连"
    public const val MCP_ERR_NAME_REQUIRED: String = "名称不能为空"
    public const val MCP_ERR_NAME_INVALID: String = "名称只能用字母、数字、下划线和连字符"
    public const val MCP_ERR_COMMAND_REQUIRED: String = "命令不能为空"
    public const val MCP_ERR_URL_REQUIRED: String = "地址不能为空"
    public const val MCP_ERR_URL_INVALID: String = "地址必须是以 http 或 https 开头的完整地址"
    public const val MCP_ERR_URL_CREDENTIALS: String = "地址不能带用户名或密码"
    public const val MCP_EDITOR_UNKNOWN_STATE: String = "读取不到这个 MCP 服务器"
    public const val MCP_EDITOR_UNKNOWN_HINT: String = "返回列表后重试；没有做任何假设"
    public const val MCP_EDITOR_FAILURE_SAVE: String = "保存失败，改动还在表单里"
    public const val MCP_EDITOR_FAILURE_UNKNOWN: String = "MCP 服务器保存失败"
    public const val MCP_EDITOR_ERRORS: String = "还有 %d 处需要修改"
    public const val MCP_EDITOR_KEEP_COMMAND: String = "已保存命令；留空表示保持不变"
    public const val MCP_EDITOR_KEEP_URL: String = "已保存地址；留空表示保持不变"
    public const val MCP_EDITOR_STORED_UNKNOWN: String = "读取不到已保存的值；留空表示保持不变"

    // ---------------------------------------------------------------------
    // P5 R2 lane: RuntimeDetailsPage (`spec/ui/v1/README.md` §1 must) and
    // EgressAllowListPage (§1 must). Appended only: every entry above belongs
    // to another lane and is never rewritten.
    // ---------------------------------------------------------------------

    // RuntimeDetailsPage: the engine, WebView, memory budget, power and FGS.
    /**
     * 与设置行文案一致，见 `spec/ui/v1/README.md` §1（设置内「运行时详情」）：
     * 同一个名字既是设置行的入口文案，也是本页标题，两处不再各写一套。
     */
    // The page title is the contract's `运行状态` (`ChatPage.swift:4242`
    // `.navigationTitle("运行状态")`), not the settings row's wording: the
    // baseline has no "运行时详情" string anywhere.
    public const val RUNTIME_TITLE: String = "运行状态"
    public const val RUNTIME_SECTION_ENGINE: String = "引擎"
    public const val RUNTIME_SECTION_WEBVIEW: String = "WebView"
    public const val RUNTIME_SECTION_MEMORY: String = "内存"
    public const val RUNTIME_SECTION_POWER: String = "电源与散热"
    public const val RUNTIME_SECTION_FGS: String = "前台服务"
    public const val RUNTIME_STATUS: String = "状态"
    public const val RUNTIME_UPTIME: String = "已运行"
    public const val RUNTIME_STOPPED: String = "已停止"
    public const val RUNTIME_STOP: String = "停止本地引擎"
    public const val RUNTIME_START: String = "启动本地引擎"
    public const val RUNTIME_STOP_CONFIRM: String = "停止本地引擎？"
    public const val RUNTIME_STOP_CONFIRM_DETAIL: String = "正在跑的任务会停下来；会话和文件都还在。"
    public const val RUNTIME_STOP_FOOTER: String = "停止后，正在跑的任务会停下来，不会再接着做。"
    public const val RUNTIME_ENGINE_UNKNOWN_HINT: String =
        "读取不到引擎状态：先刷新再试，不提供停止或启动"
    public const val RUNTIME_UPTIME_UNDER_MINUTE: String = "不到 1 分钟"
    public const val RUNTIME_UPTIME_MINUTES: String = "%d 分钟"
    public const val RUNTIME_UPTIME_HOURS: String = "%d 小时"
    public const val RUNTIME_UPTIME_HOURS_MINUTES: String = "%d 小时 %d 分钟"
    public const val RUNTIME_WEBVIEW_PROVIDER: String = "提供方"
    public const val RUNTIME_WEBVIEW_VERSION: String = "版本号"
    public const val RUNTIME_WEBVIEW_FEATURES: String = "特性探测"
    public const val RUNTIME_WEBVIEW_VERSION_HINT: String = "版本号只作遥测，不作判据"
    public const val RUNTIME_WEBVIEW_FEATURE_HINT: String = "按特性探测，不按版本号判断"
    public const val RUNTIME_WEBVIEW_GATE_MISSING: String = "WebView 缺少必需特性：页面会诚实降级"
    public const val RUNTIME_FEATURE_SUPPORTED: String = "支持"
    public const val RUNTIME_FEATURE_UNSUPPORTED: String = "不支持"
    public const val RUNTIME_MEMORY_TIER_HINT: String = "启动时按本机内存选一次，运行中不改档"
    public const val RUNTIME_MEMORY_BUDGET: String = "预算"
    public const val RUNTIME_MEMORY_OVER_BUDGET: String = "已超出内存预算"
    public const val RUNTIME_THERMAL: String = "热压力"
    public const val RUNTIME_THERMAL_HINT: String = "Android 热档位比 iOS 粗；未取到信号时不按正常处理"
    public const val RUNTIME_THERMAL_NONE: String = "正常"
    public const val RUNTIME_THERMAL_LIGHT: String = "轻度"
    public const val RUNTIME_THERMAL_MODERATE: String = "中度"
    public const val RUNTIME_THERMAL_SEVERE: String = "重度"
    public const val RUNTIME_THERMAL_CRITICAL: String = "严重"
    public const val RUNTIME_THERMAL_EMERGENCY: String = "紧急"
    public const val RUNTIME_THERMAL_SHUTDOWN: String = "关机"
    public const val RUNTIME_THERMAL_PRESSURE: String = "热压力偏高：后台工作会被保守化"
    public const val RUNTIME_BATTERY: String = "电量"
    public const val RUNTIME_BATTERY_PERCENT: String = "%d%%"
    public const val RUNTIME_CHARGING: String = "充电状态"
    public const val RUNTIME_CHARGING_ON: String = "充电中"
    public const val RUNTIME_CHARGING_OFF: String = "未充电"
    public const val RUNTIME_BATTERY_SAVER: String = "省电模式"
    public const val RUNTIME_BATTERY_SAVER_ON: String = "已开启"
    public const val RUNTIME_BATTERY_SAVER_OFF: String = "已关闭"
    public const val RUNTIME_FGS: String = "前台服务可用性"
    public const val RUNTIME_FGS_AVAILABLE: String = "可用"
    public const val RUNTIME_FGS_AVAILABLE_HINT: String = "应用退到后台时仍能继续回合"
    public const val RUNTIME_FGS_UNAVAILABLE_HINT: String = "前台服务不可用：后台回合会降级为仅前台"
    public const val RUNTIME_EMPTY: String = "没有可显示的运行时信息"
    public const val RUNTIME_EMPTY_HINT: String =
        "宿主报告了空快照，没有任何一项被测量；不会用 0 或默认档位填充"
    public const val RUNTIME_UNKNOWN_STATE: String = "运行时状态未知"
    public const val RUNTIME_UNKNOWN_HINT: String =
        "宿主没有报告运行时状态，无法判断这些值；不会用 0 代替"
    public const val RUNTIME_FAILED: String = "运行时状态读取失败"
    public const val RUNTIME_UNMEASURED_HINT: String =
        "未测量的值显示为未知，不会当成 0 或默认档位"

    // RuntimeDetailsPage's iOS trio, on top of the Android diagnostics groups
    // (ChatPage.swift:4189 `本次运行`, :4198 `最近出错`). Every row is a host read,
    // so an absent read says 未知 / 读取不到: 0 is a measurement, never a placeholder.
    public const val RUNTIME_SECTION_RUN: String = "本次运行"
    public const val RUNTIME_SECTION_ERROR: String = "最近出错"
    public const val RUNTIME_MODEL_REQUESTS: String = "模型调用"
    public const val RUNTIME_INPUT_TOKENS: String = "输入 Token"
    public const val RUNTIME_OUTPUT_TOKENS: String = "输出 Token"
    public const val RUNTIME_NO_ERROR: String = "最近没有出错"
    public const val RUNTIME_ERROR_UNREAD: String = "读取不到最近一次出错"

    // L76: the two sentences the runtime page says ONCE instead of under every row.
    /**
     * The iOS status line, folded the way the baseline folds it.
     *
     * `ChatPage.swift:4168-4176` builds `statusValue` as
     * `"\(model.displayStatus) · 已运行\(elapsed)"` and `:4183-4186` prints it in
     * one `状态` row; Android used to split that row into 状态 + 已运行. `%s` is
     * the engine word (`运行中`) and the second one the formatted duration.
     */
    public const val RUNTIME_STATUS_UPTIME_FORMAT: String = "%s · 已运行%s"

    /**
     * The page's single explanation for unmeasured values: which groups the host
     * did not report.
     *
     * L64 counted six copies of `SETTINGS_UNKNOWN_HINT` on one screen (16 in the
     * whole page). The baseline has no such sentence at all, so the Android read
     * says it once, with the group names, and the rows say only 未知.
     */
    public const val RUNTIME_UNMEASURED_GROUPS: String = "这台宿主没有报告这些状态：%s"

    /** The separator between group names in [RUNTIME_UNMEASURED_GROUPS]. */
    public const val RUNTIME_UNMEASURED_GROUPS_SEPARATOR: String = "、"

    // EgressAllowListPage: the effective rules, the deny-all empty table and
    // the matching form each entry stands for.
    /**
     * 与设置行文案一致，见 `spec/ui/v1/README.md` §1（设置内「出网白名单」）：
     * 同一个名字既是设置行的入口文案，也是本页标题，两处不再各写一套。
     */
    // `NativeShell.swift:541` `.navigationTitle("网络访问")`; the allow-list
    // wording stays in the body copy (`EGRESS_FAILED`…), never in the title.
    public const val EGRESS_TITLE: String = "网络访问"
    public const val EGRESS_RULES: String = "地址"
    public const val EGRESS_RULE_COUNT: String = "%d 个地址"
    public const val EGRESS_POLICY: String = "当前策略"
    public const val EGRESS_DENY_ALL: String = "全部拒绝"
    public const val EGRESS_DENY_ALL_HINT: String =
        "白名单为空：任何出网请求都会被拒绝。这是当前生效的策略，不是读取失败，也不是没有数据。"
    public const val EGRESS_ALLOW_ALL: String = "全部放行"
    public const val EGRESS_ALLOW_ALL_HINT: String =
        "规则包含 *：任何 http(s) 目标都会被放行，白名单不再限制出网"
    public const val EGRESS_UNKNOWN_STATE: String = "白名单状态未知"
    public const val EGRESS_UNKNOWN_HINT: String =
        "宿主没有报告出网白名单，无法判断放行还是拒绝"
    public const val EGRESS_FAILED: String = "出网白名单读取失败"
    public const val EGRESS_FORM_EXACT: String = "精确主机"
    public const val EGRESS_FORM_WILDCARD: String = "通配后缀"
    public const val EGRESS_FORM_ANY: String = "任意主机"
    public const val EGRESS_DETAIL_ANY_SCHEME: String = "任意 http(s) scheme"
    public const val EGRESS_DETAIL_ANY_PORT: String = "任意端口"
    public const val EGRESS_DETAIL_PORT: String = "端口 %d"
    public const val EGRESS_DETAIL_WILDCARD: String = "包含后缀主机本身"
    public const val EGRESS_DETAIL_ANY_HOST: String = "任何 http(s) 主机"
    public const val EGRESS_GRAMMAR: String = "规则语法"
    public const val EGRESS_GRAMMAR_EXACT: String = "精确主机：只匹配这个主机"
    public const val EGRESS_GRAMMAR_WILDCARD: String = "*.suffix：匹配后缀主机本身和所有子域"
    public const val EGRESS_GRAMMAR_ANY: String = "*：任何 http(s) 主机与端口"
    public const val EGRESS_GRAMMAR_PORT: String = "写端口时比较生效端口，不写端口则任意端口"
    public const val EGRESS_GRAMMAR_EMPTY: String = "空名单 = 全部拒绝，不会回退成默认放行"
    public const val EGRESS_READ_ONLY: String = "这个页面只显示当前生效的规则；修改由宿主配置完成"

    // ---------------------------------------------------------------------
    // P5 S1 lane: NativeAutomationPage, NativeConfigurationPage and
    // WebSurfacePage (all §1 `must`). Appended only: every entry above belongs
    // to another lane and is never rewritten.
    // ---------------------------------------------------------------------

    // NativeAutomationPage: the schedule catalog, one schedule's detail and its
    // delivery history. The host supplies every time string; the page never
    // reads a clock.
    public const val AUTOMATION_TITLE: String = "定时任务"
    public const val AUTOMATION_EMPTY: String = "还没有定时任务"
    // `NativeAutomationPage.swift:23`: the baseline's sentence uses a half-width
    // comma; L11 recorded the difference and left the copy alone, L82 aligns it.
    public const val AUTOMATION_EMPTY_HINT: String = "到点让它自己跑,结果回到原会话。"
    public const val AUTOMATION_NEW: String = "新建任务"
    // The bar's 新建 and the empty block's 新建任务 are two different labels in the
    // baseline: the toolbar item is 新建 (`NativeAutomationPage.swift:83`), the
    // CTA under the empty-state hint is 新建任务 (:30).
    public const val AUTOMATION_NEW_SHORT: String = "新建"
    // The failure section's header: `Section("需要处理")` (:70) on the catalog,
    // `Section("错误")` on the detail (:150) and the history (:203).
    public const val AUTOMATION_ATTENTION: String = "需要处理"
    public const val AUTOMATION_ERROR: String = "错误"
    public const val AUTOMATION_EDIT: String = "编辑任务"
    // The detail row's verb. The baseline's swipe action and menu item are both the
    // short 编辑 (`NativeAutomationPage.swift:63`, `:157`); the host handoff's own
    // label above stays 编辑任务, so this one is appended rather than renamed.
    public const val AUTOMATION_EDIT_SHORT: String = "编辑"
    // The row's other destructive affordance and its confirmation
    // (`NativeAutomationPage.swift:64`, `:102`–`:109`; the detail page's menu
    // carries the same two verbs at `:157`–`:158`).
    public const val AUTOMATION_DELETE: String = "删除"
    public const val AUTOMATION_DELETE_TASK: String = "删除任务"
    public const val AUTOMATION_CONFIRM_DELETE: String = "删除此自动化任务？"
    public const val AUTOMATION_CONFIRM_DELETE_MESSAGE: String =
        "删除会停止后续投递，并保留已保存的会话历史。"
    public const val AUTOMATION_REFRESH: String = "刷新"
    // Retired by L11: the aligned page prints the host's own sentence under
    // `需要处理` (NativeAutomationPage.swift:70) instead of a page-authored label.
    public const val AUTOMATION_LOAD_FAILED: String = "定时任务读取失败"
    public const val AUTOMATION_UNKNOWN_STATE: String = "定时任务状态未知"
    public const val AUTOMATION_UNKNOWN_HINT: String =
        "宿主没有报告定时任务，无法判断有没有；不会用 0 条代替"
    public const val AUTOMATION_UNKNOWN_DETAIL: String =
        "任务数量、下次计划和投递记录都不可读"
    public const val AUTOMATION_UNMEASURED_HINT: String =
        "未测量的值显示为未知，不会当成 0 或已停止"
    public const val AUTOMATION_ACTIVE: String = "活动"
    public const val AUTOMATION_STOPPED: String = "已停止"
    public const val AUTOMATION_STATUS_UNKNOWN: String = "任务状态未知"
    public const val AUTOMATION_STATUS: String = "状态"
    public const val AUTOMATION_RULE: String = "规则"
    public const val AUTOMATION_NEXT_RUN: String = "下次计划"
    public const val AUTOMATION_LATEST_DELIVERY: String = "最近投递"
    public const val AUTOMATION_SESSION: String = "会话"
    public const val AUTOMATION_SESSION_UNKNOWN: String = "会话未知"
    public const val AUTOMATION_DETAIL_TITLE: String = "任务详情"
    public const val AUTOMATION_PROMPT: String = "提醒内容"
    public const val AUTOMATION_TASK_COUNT: String = "%d 个任务"
    public const val AUTOMATION_NOT_FOUND: String = "任务不存在"
    public const val AUTOMATION_NOT_FOUND_HINT: String = "它可能已被删除；返回列表后刷新"
    public const val AUTOMATION_READ_ONLY: String =
        "这一页只显示宿主报告的定时任务；新建、编辑和删除由宿主完成"
    public const val AUTOMATION_HISTORY_TITLE: String = "投递记录"
    public const val AUTOMATION_HISTORY_OPEN: String = "查看投递记录"
    public const val AUTOMATION_HISTORY_EMPTY: String = "没有投递记录"
    public const val AUTOMATION_HISTORY_EMPTY_HINT: String = "这次还没留下结果。"
    public const val AUTOMATION_HISTORY_UNKNOWN: String = "投递记录状态未知"
    public const val AUTOMATION_HISTORY_UNKNOWN_HINT: String =
        "宿主没有报告投递记录，无法判断有没有"
    public const val AUTOMATION_HISTORY_UNKNOWN_DETAIL: String =
        "这次计划的投递记录没有报告"
    public const val AUTOMATION_HISTORY_FAILED: String = "投递记录读取失败"
    public const val AUTOMATION_HISTORY_MORE: String = "加载更早记录"
    public const val AUTOMATION_DELIVERED_AT: String = "投递时间"
    public const val AUTOMATION_PLANNED_AT: String = "计划时间"
    // `Text("计划时间：\(item.scheduledAt)")` (`NativeAutomationPage.swift:193`):
    // the baseline's line is one sentence with a full-width colon, not a label plus
    // a value.
    public const val AUTOMATION_PLANNED_AT_FORMAT: String = "计划时间：%s"
    public const val AUTOMATION_META_FORMAT: String = "%s · %s"

    // L82: the four row labels `ScheduleDetailPage` / `ScheduleHistoryPage` draw and
    // this page did not have (`NativeAutomationPage.swift:129`, `:130`, `:136`,
    // `:142`–`:145`). `AUTOMATION_LATEST_DELIVERY` above is a detail *row* label the
    // baseline does not draw there; the baseline's line is the one below it.
    public const val AUTOMATION_SECTION_REMINDER: String = "提醒"
    public const val AUTOMATION_NAME: String = "名称"
    public const val AUTOMATION_SECTION_HISTORY: String = "投递记录"
    public const val AUTOMATION_LATEST_DELIVERY_FORMAT: String = "最近投递：%s"

    // NativeConfigurationPage: the session-level settings groups and the plugin
    // inventory. Values are host-formatted; an unread value is 未知.
    // `NativeConfigurationPage.swift:28` `.navigationTitle("插件")`; the iOS
    // page never titles itself 本会话设置 (that is only a menu item wording,
    // `ChatPage.swift:274`).
    public const val CONFIGURATION_TITLE: String = "插件与工具"
    public const val CONFIGURATION_DONE: String = "完成"
    public const val CONFIGURATION_REFRESH: String = "刷新"
    public const val CONFIGURATION_INTRO: String = "安装、启用和配置插件"
    public const val CONFIGURATION_EMPTY: String = "还没有可配置的会话级设置"
    public const val CONFIGURATION_EMPTY_HINT: String =
        "宿主报告了空快照；不会用默认值填充"
    public const val CONFIGURATION_UNKNOWN_STATE: String = "本会话设置状态未知"
    public const val CONFIGURATION_UNKNOWN_HINT: String =
        "宿主没有报告会话级与插件配置，无法判断有哪些设置"
    public const val CONFIGURATION_UNKNOWN_DETAIL: String =
        "设置分组、默认权限和插件列表都不可读"
    public const val CONFIGURATION_UNMEASURED_HINT: String =
        "未测量的值显示为未知，不会当成默认值"
    public const val CONFIGURATION_LOAD_FAILED: String = "本会话设置读取失败"
    public const val CONFIGURATION_SESSION: String = "会话"
    public const val CONFIGURATION_WRITABLE: String = "读写状态"
    public const val CONFIGURATION_WRITABLE_YES: String = "可修改"
    public const val CONFIGURATION_WRITABLE_NO: String = "只读"
    public const val CONFIGURATION_WRITABLE_UNKNOWN: String = "读写状态未知"
    public const val CONFIGURATION_GROUP_ITEMS: String = "%d 项"
    public const val CONFIGURATION_GROUP_UNKNOWN: String = "设置项未知"
    public const val CONFIGURATION_GROUP_EMPTY: String = "这个分组没有设置项"
    public const val CONFIGURATION_FIELD_OVERRIDDEN: String = "已改成你自己的值"
    public const val CONFIGURATION_WEB_SEARCH: String = "网页搜索与抓取"
    public const val CONFIGURATION_DEFAULT_PERMISSION: String = "新会话默认权限"
    public const val CONFIGURATION_DEFAULT_PERMISSION_ROW: String = "默认权限"
    public const val CONFIGURATION_DEFAULT_PERMISSION_HINT: String =
        "只影响之后新开的会话；正在聊的这个由输入框上方的菜单改"
    public const val CONFIGURATION_DEFAULT_PERMISSION_UNKNOWN: String = "默认权限未知"
    public const val CONFIGURATION_PERMISSION_UNKNOWN: String = "权限预设状态未知"
    public const val CONFIGURATION_PERMISSION_EMPTY: String = "没有可选的权限预设"
    public const val CONFIGURATION_PERMISSION_COUNT: String = "%d 个预设"
    public const val CONFIGURATION_PLUGIN_INFO: String = "插件说明"
    public const val CONFIGURATION_PLUGIN_SCOPE: String = "管理范围"
    public const val CONFIGURATION_PLUGIN_INFO_HINT: String =
        "只有真正加载起来的插件才会显示为已启用"
    public const val CONFIGURATION_PLUGIN_INFO_UNKNOWN: String =
        "宿主没有给插件管理说明；不会假设手机可以安装插件"
    public const val CONFIGURATION_ADD_DISABLED: String = "添加插件"
    public const val CONFIGURATION_ADD_DISABLED_HINT: String =
        "宿主不支持从手机安装插件；安装和启用需在桌面 DSH 管理"
    public const val CONFIGURATION_EXPERIMENTAL: String = "实验插件"
    public const val CONFIGURATION_EXPERIMENTAL_UNKNOWN: String =
        "宿主没有报告实验插件，无法判断它们有没有加载"
    public const val CONFIGURATION_EXPERIMENTAL_EMPTY: String = "宿主没有报告实验插件"
    public const val CONFIGURATION_PLUGIN_LOADED: String = "已加载"
    public const val CONFIGURATION_PLUGIN_NOT_LOADED: String = "未加载"
    public const val CONFIGURATION_INSTALLED: String = "已加载插件"
    public const val CONFIGURATION_INSTALLED_EMPTY: String = "引擎还没给出插件列表"
    public const val CONFIGURATION_INSTALLED_UNKNOWN: String = "插件列表未知"
    public const val CONFIGURATION_INSTALLED_UNKNOWN_HINT: String =
        "宿主没有报告插件列表，无法判断有没有"
    public const val CONFIGURATION_INSTALLED_COUNT: String = "%d 个条目"
    public const val CONFIGURATION_PLUGIN_ENABLED: String = "已启用"
    public const val CONFIGURATION_PLUGIN_DISABLED: String = "未启用"
    public const val CONFIGURATION_PLUGIN_ENTRY: String = "条目 %s"
    public const val CONFIGURATION_PLUGIN_PHASE: String = "阶段 %s"
    public const val CONFIGURATION_PARTIAL_FAILURE: String = "部分设置读取失败"
    public const val CONFIGURATION_PARTIAL_FAILURE_FORMAT: String = "部分设置读取失败：%s"
    public const val CONFIGURATION_PLUGIN_META_FORMAT: String = "%s · %s"
    public const val CONFIGURATION_READ_ONLY: String =
        "这一页显示宿主报告的值；保存与撤销由宿主完成"

    // WebSurfacePage: the full-screen WebView host. The page owns only the
    // startup/failure/unknown chrome around the host-supplied surface.
    public const val WEB_SURFACE_TITLE: String = "DSH 页面"
    public const val WEB_SURFACE_SURFACE_LABEL: String = "DSH Web 页面"
    public const val WEB_SURFACE_EMPTY: String = "Web 页面还没有可显示的内容"
    public const val WEB_SURFACE_EMPTY_HINT: String =
        "宿主报告了空快照；不会用 0 或空白页冒充已加载"
    public const val WEB_SURFACE_UNKNOWN_STATE: String = "Web 页面状态未知"
    public const val WEB_SURFACE_UNKNOWN_HINT: String =
        "宿主没有报告 Web 页面状态，无法判断是否加载"
    public const val WEB_SURFACE_UNKNOWN_DETAIL: String =
        "引擎、WebView 挂载和页面地址都不可读"
    public const val WEB_SURFACE_FAILED: String = "本地页面暂时打不开"
    public const val WEB_SURFACE_FAILED_HINT: String =
        "可以重试、检查模型服务配置，或切换到原生恢复界面"
    public const val WEB_SURFACE_PREPARING: String = "正在准备本地引擎"
    public const val WEB_SURFACE_PREPARING_HINT: String =
        "引擎就绪后这里显示完整 DSH 页面"
    public const val WEB_SURFACE_ENGINE: String = "引擎"
    public const val WEB_SURFACE_ENGINE_READY: String = "已就绪"
    public const val WEB_SURFACE_ENGINE_STOPPED: String = "已停止"
    public const val WEB_SURFACE_WEBVIEW: String = "WebView 挂载"
    public const val WEB_SURFACE_ATTACHED: String = "已挂载"
    public const val WEB_SURFACE_NOT_ATTACHED: String = "未挂载"
    public const val WEB_SURFACE_PAGE: String = "页面"
    public const val WEB_SURFACE_PAGE_LOADED: String = "已加载"
    public const val WEB_SURFACE_PAGE_LOADING: String = "加载中"
    public const val WEB_SURFACE_URL: String = "地址"
    public const val WEB_SURFACE_RETRY: String = "重试"
    public const val WEB_SURFACE_MODEL_SETTINGS: String = "模型配置"
    public const val WEB_SURFACE_NATIVE_RECOVERY: String = "原生恢复"
    public const val WEB_SURFACE_NATIVE_AVAILABLE: String = "可用"
    public const val WEB_SURFACE_DETAILS_SHOW: String = "查看状态详情"
    public const val WEB_SURFACE_DETAILS_HIDE: String = "收起状态详情"
    public const val WEB_SURFACE_UNMEASURED_HINT: String =
        "未测量的值显示为未知，不会当成已加载"

    // ---------------------------------------------------------------------
    // P5 X2 lane: the five `later` probe pages
    // (`spec/ui/v1/README.md` §1: ProbesPage / BackgroundPage / TaskScreenPage /
    // ExportPage / DailyBriefPage). Appended only: every entry above belongs to
    // another lane and is never rewritten. The baseline copy is English; these
    // are the zh strings the rest of the UI speaks, with the same meaning, and
    // `UNKNOWN` above is the one word an unread value may show.
    // ---------------------------------------------------------------------

    // Two-valued host facts. A fact that could not be read is `UNKNOWN`, never
    // `NO`; these two words therefore only ever follow a measured boolean.
    public const val YES: String = "是"
    public const val NO: String = "否"

    // ProbesPage: the environment reads, the run actions and the G0 report.
    //
    // L75: the page title is the baseline's own word, not a translation of it.
    // `ProbesPage.swift:38` is `.navigationTitle("Probes")` — an English title on
    // an English-only probe page, exactly like `MEMORY_PROBE_TITLE` below
    // (`MemoryPage.swift:40`). The previous 设备探针 was the one string on the
    // screen that existed nowhere in the baseline (page_structure_check
    // `title-mismatch`), and the page's own sections and actions were already
    // English, so the Chinese title was also the only non-English control on it.
    public const val PROBES_TITLE: String = "Probes"
    public const val PROBES_SECTION_ENVIRONMENT: String = "运行环境"
    public const val PROBES_ENVIRONMENT: String = "环境"
    public const val PROBES_OS: String = "系统"
    public const val PROBES_BUNDLE: String = "应用标识"
    public const val PROBES_SECTION_ACTIONS: String = "操作"
    public const val PROBES_RUN_ALL: String = "运行全部探针"
    public const val PROBES_RUN_GROUP: String = "运行「%s」"
    public const val PROBES_RESET: String = "重置结果"
    public const val PROBES_RUNNING: String = "正在运行…"
    public const val PROBES_SECTION_SUMMARY: String = "结果"
    public const val PROBES_COUNTS_LABEL: String = "通过 / 失败 / 信息"
    public const val PROBES_COUNTS: String = "%s / %s / %s"
    public const val PROBES_G0: String = "G0 门槛"
    public const val PROBES_PASS: String = "通过"
    public const val PROBES_FAIL: String = "失败"
    public const val PROBES_INFO: String = "信息"
    public const val PROBES_G0_PASSED: String = "通过"
    public const val PROBES_G0_FAILED: String = "不通过"
    public const val PROBES_G0_FAILED_LIST: String = "G0 未通过：%s"
    public const val PROBES_SECTION_ROWS: String = "探针记录（%d 条）"
    public const val PROBES_STATUS_TEXT: String = "状态说明"
    public const val PROBES_RECORDED: String = "记录"
    public const val PROBES_SECTION_THRESHOLDS: String = "G0 阈值"
    public const val PROBES_THRESHOLD_GATING: String = "计入 G0"
    public const val PROBES_THRESHOLD_ROW: String = "G0 %s"
    public const val PROBES_THRESHOLD_NON_GATING: String = "不计入 G0"
    public const val PROBES_THRESHOLD_MET: String = "达标"
    public const val PROBES_THRESHOLD_NOT_MET: String = "未达标"
    public const val PROBES_THRESHOLD_SOURCE: String = "来源：%s"
    public const val PROBES_EMPTY: String = "这次启动还没有跑过探针"
    public const val PROBES_EMPTY_HINT: String = "探针只在运行后产生记录；设备上的数值在运行前保持未知"
    public const val PROBES_UNKNOWN_STATE: String = "探针结果未知"
    public const val PROBES_UNKNOWN_HINT: String =
        "宿主没有报告探针结果，无法判断有没有跑过；不会显示 0 条"
    public const val PROBES_FAILED: String = "探针结果读取失败"
    public const val PROBES_UNMEASURED_HINT: String = "未测量的值显示为未知，不会当成 0"

    // BackgroundPage: the matrix cell being run, its observation and the log.
    //
    // L75: `BackgroundPage.swift:171` is `.navigationTitle("Background")`, and the
    // page's sections and actions are English too (`Start cell`, `Cancel`,
    // `Scenario`), so 后台保活 was a translation the baseline never had. The
    // dev-tools index row that opens this page shows this same constant, so the
    // row a person taps and the header they land on stay the same word.
    public const val BACKGROUND_TITLE: String = "Background"
    public const val BACKGROUND_SECTION_RUN: String = "运行"
    public const val BACKGROUND_SECTION_OBSERVATION: String = "观测"
    public const val BACKGROUND_SECTION_CELLS: String = "矩阵结果"
    public const val BACKGROUND_SECTION_TRANSITIONS: String = "迁移记录"
    public const val BACKGROUND_SCENARIO: String = "场景"
    // The two segment words the baseline's `Picker("Scenario")` draws
    // (`BackgroundPage.swift:31` -> `ProbeKit/BackgroundProbe.swift:37-38`:
    // "Background" / "Lock"). The L82 lane reads the picker's own options as
    // control labels, so they keep the baseline language like the section titles.
    public const val BACKGROUND_SCENARIO_BACKGROUND: String = "Background"
    public const val BACKGROUND_SCENARIO_LOCK: String = "Lock"
    public const val BACKGROUND_PHASE: String = "阶段"
    public const val BACKGROUND_STATUS: String = "状态说明"
    public const val BACKGROUND_RUNNING: String = "运行中"
    public const val BACKGROUND_IDLE: String = "未运行"
    public const val BACKGROUND_START: String = "开始这一格"
    public const val BACKGROUND_CANCEL: String = "取消这一次"
    public const val BACKGROUND_RUN_HINT: String =
        "开始后把应用退到后台（锁屏格则锁屏），保持到窗口结束再回来；宿主会记录这次迁移"
    public const val BACKGROUND_WINDOW: String = "系统窗口"
    public const val BACKGROUND_LOCK_OBSERVED: String = "观测到锁屏"
    public const val BACKGROUND_BACKGROUND_SECONDS: String = "后台时长"
    public const val BACKGROUND_RECOVERY_SECONDS: String = "恢复耗时"
    public const val BACKGROUND_SECONDS: String = "%s 秒"
    public const val BACKGROUND_RECOVERED: String = "已恢复"
    public const val BACKGROUND_HOST_STATE: String = "宿主状态"
    public const val BACKGROUND_OBSERVED: String = "实测时长"
    public const val BACKGROUND_HELD: String = "占满窗口"
    public const val BACKGROUND_CELL_TITLE: String = "%s · %s"
    public const val BACKGROUND_CELL_COUNT: String = "%d 格"
    public const val BACKGROUND_CELLS_EMPTY: String = "还没有矩阵结果"
    public const val BACKGROUND_TRANSITION_COUNT: String = "%d 条"
    public const val BACKGROUND_TRANSITION_EMPTY: String = "还没有记录到迁移"
    public const val BACKGROUND_EMPTY: String = "宿主没有测量任何后台数据"
    public const val BACKGROUND_EMPTY_HINT: String =
        "这个页面只报告实际观测到的后台与锁屏数据，不用默认值填充"
    public const val BACKGROUND_UNKNOWN_STATE: String = "后台诊断未知"
    public const val BACKGROUND_UNKNOWN_HINT: String =
        "宿主没有报告后台诊断，无法判断有没有跑过；不会显示 0 秒"
    public const val BACKGROUND_FAILED: String = "后台诊断读取失败"
    public const val BACKGROUND_UNMEASURED_HINT: String =
        "未测量的值显示为未知，不会当成 0 或未运行"

    // TaskScreenPage: the status line, the best-effort dimming and its report.
    //
    // L75: `TaskScreenPage.swift:60` is `.navigationTitle("Screen")` — the page is
    // the probe app's "Screen" page, not a 任务屏 in the product's vocabulary. The
    // in-page section label keeps `TASK_SCREEN_SECTION_EN` ("Task screen", the
    // baseline's `PageSection` title); only the bar title takes the baseline word.
    public const val TASK_SCREEN_TITLE: String = "Screen"
    public const val TASK_SCREEN_SECTION: String = "任务屏"
    public const val TASK_SCREEN_DESCRIPTION: String =
        "纯黑低亮度屏：没有计时器，没有动画，只有状态行会随调用方重建而改变。"
    public const val TASK_SCREEN_STATUS_LINE: String = "状态行"
    public const val TASK_SCREEN_STATUS_PLACEHOLDER: String = "任务屏状态行"
    public const val TASK_SCREEN_DEFAULT_STATUS: String = "phone DSH 任务屏"
    public const val TASK_SCREEN_SHOW: String = "显示任务屏"
    public const val TASK_SCREEN_CLOSE: String = "关闭任务屏"
    public const val TASK_SCREEN_SECTION_REPORT: String = "报告"
    public const val TASK_SCREEN_PRESENTED_LABEL: String = "显示状态"
    public const val TASK_SCREEN_PRESENTED: String = "已显示"
    public const val TASK_SCREEN_NOT_PRESENTED: String = "未显示"
    public const val TASK_SCREEN_BRIGHTNESS: String = "最低亮度"
    public const val TASK_SCREEN_BRIGHTNESS_HINT: String =
        "亮度接口是尽力而为且全局的；设备是否真的变暗未验证"
    public const val TASK_SCREEN_PREVIEW_HINT: String =
        "黑屏本身由宿主的平台层呈现，这一页只负责状态行和读取到的报告"
    public const val TASK_SCREEN_EMPTY: String = "还没有任务屏数据"
    public const val TASK_SCREEN_EMPTY_HINT: String = "宿主报告了空快照；不会用 0 或「未显示」冒充"
    public const val TASK_SCREEN_UNKNOWN_STATE: String = "任务屏状态未知"
    public const val TASK_SCREEN_UNKNOWN_HINT: String = "宿主没有报告任务屏数据，无法判断有没有显示过"
    public const val TASK_SCREEN_FAILED: String = "任务屏读取失败"
    public const val TASK_SCREEN_UNMEASURED_HINT: String =
        "未测量的值显示为未知，不会当成 0 或未显示"

    // ExportPage: the report facts, the written file and its preview.
    public const val EXPORT_TITLE: String = "导出诊断"
    public const val EXPORT_SECTION_REPORT: String = "报告"
    public const val EXPORT_STATUS: String = "状态"
    public const val EXPORT_ENVIRONMENT: String = "环境"
    public const val EXPORT_DEVICE: String = "设备"
    public const val EXPORT_FORMAT_VERSION: String = "格式版本"
    public const val EXPORT_FILE: String = "文件"
    public const val EXPORT_FILE_NOT_WRITTEN: String = "还没写"
    public const val EXPORT_WRITE: String = "写报告"
    public const val EXPORT_SHARE: String = "分享文件"
    public const val EXPORT_PATH_HINT: String = "写好的文件放进仓库的验收目录，文件名用日期和设备名"
    public const val EXPORT_SECTION_PREVIEW: String = "预览"
    public const val EXPORT_PREVIEW_LINES: String = "%d 行"
    public const val EXPORT_PREVIEW_MORE: String = "… 还有 %d 行"
    public const val EXPORT_PREVIEW_EMPTY: String = "没有可预览的内容"
    public const val EXPORT_EMPTY: String = "还没有可导出的诊断报告"
    public const val EXPORT_EMPTY_HINT: String = "宿主报告了空快照；不会用空报告冒充已测量"
    public const val EXPORT_UNKNOWN_STATE: String = "诊断报告未知"
    public const val EXPORT_UNKNOWN_HINT: String = "宿主没有报告诊断报告，无法判断有没有内容"
    public const val EXPORT_FAILED: String = "导出诊断包读取失败"
    public const val EXPORT_WRITE_FAILED: String = "写报告失败，上一份报告还在"
    public const val EXPORT_UNMEASURED_HINT: String = "未测量的值显示为未知，不会当成空报告"
    // L81: 写报告 answers with this because this host carries no diagnostic-bundle
    // command (no format, no writer, no provider root to share one from). The page
    // is a real settings row, so the verb stays and the answer names the gap.
    public const val EXPORT_UNAVAILABLE: String =
        "本宿主没有导出诊断包的命令，本次没有写出任何文件。"

    // DailyBriefPage: the snapshot, the items, the sources and this run's issues.
    public const val DAILY_BRIEF_TITLE: String = "每日简报"
    public const val DAILY_BRIEF_NO_BRIEF: String = "还没有简报"
    public const val DAILY_BRIEF_LAST_SUCCESS: String = "最近成功 %s"
    public const val DAILY_BRIEF_LAST_ATTEMPT: String = "最近尝试 %s"
    public const val DAILY_BRIEF_NO_SOURCE_HINT: String = "添加来源后，打开页面就会更新"
    public const val DAILY_BRIEF_REFRESH: String = "刷新"
    public const val DAILY_BRIEF_REFRESHING: String = "正在更新…"
    public const val DAILY_BRIEF_SECTION_LATEST: String = "最新一期"
    public const val DAILY_BRIEF_ITEMS_EMPTY: String = "还没有可显示的内容"
    public const val DAILY_BRIEF_ITEMS_EMPTY_NO_SOURCE: String =
        "先添加一个 RSS 或 Atom 来源。已有内容会保存在本机，离线也能看。"
    // `DailyBriefPage.swift:82`: "下拉或点右上角刷新；失败时不会清空上一期。" The
    // toolbar's 刷新 is the top-right control on both platforms, and the baseline
    // sentence names it.
    public const val DAILY_BRIEF_ITEMS_EMPTY_SOURCES: String = "下拉或点右上角刷新；失败时不会清空上一期。"
    public const val DAILY_BRIEF_SOURCE_COUNT: String = "%d 个来源"
    public const val DAILY_BRIEF_SECTION_SOURCES: String = "资讯来源"
    public const val DAILY_BRIEF_SHARE: String = "分享本期"
    public const val DAILY_BRIEF_SOURCE_ENABLED: String = "已启用"
    public const val DAILY_BRIEF_SOURCE_DISABLED: String = "已停用"
    public const val DAILY_BRIEF_ENABLE: String = "启用"
    public const val DAILY_BRIEF_DISABLE: String = "停用"
    public const val DAILY_BRIEF_REMOVE: String = "删除"
    public const val DAILY_BRIEF_ADD_SOURCE: String = "添加 RSS 或 Atom 来源"
    public const val DAILY_BRIEF_SECTION_REPORT: String = "本次更新"
    public const val DAILY_BRIEF_REPORT_ITEMS: String = "%d 条内容"
    public const val DAILY_BRIEF_REPORT_NEW: String = "新增 %d"
    public const val DAILY_BRIEF_REPORT_NETWORK: String = "网络 %s"
    public const val DAILY_BRIEF_REPORT_MODEL: String = "模型 %d"
    public const val DAILY_BRIEF_SECTION_ISSUES: String = "本次更新问题"
    public const val DAILY_BRIEF_ISSUE_COUNT: String = "%d 个问题"
    public const val DAILY_BRIEF_ISSUES_EMPTY: String = "这次没有来源报错"
    public const val DAILY_BRIEF_EMPTY: String = "还没有简报"
    public const val DAILY_BRIEF_EMPTY_HINT: String =
        "宿主报告了空快照；不会用 0 条内容填充"
    public const val DAILY_BRIEF_UNKNOWN_STATE: String = "简报状态未知"
    public const val DAILY_BRIEF_UNKNOWN_HINT: String =
        "宿主没有报告每日简报，无法判断有没有内容；不会显示 0 条"
    public const val DAILY_BRIEF_FAILED: String = "简报读取失败"
    public const val DAILY_BRIEF_UNMEASURED_HINT: String = "未测量的值显示为未知，不会当成 0"

    // ---------------------------------------------------------------------
    // N5 lane: the three pages mirrored line by line from
    // `examples/probe-app/PhoneDSHProbe/FilesPage.swift`,
    // `SessionActivityPage.swift` and `PDSHShellPage.swift`.
    //
    // Appended only: every entry above belongs to another lane and is never
    // rewritten. The copy is the baseline's, character for character — including
    // the half-width commas in the shell page's sentences, which are the
    // baseline's, not a typo here.
    // ---------------------------------------------------------------------

    // FilesPage: the search field, the group title and the empty state
    // (`FilesPage.swift:21` 「手机工作区」, `:56` 「搜索文件」, `:104` / `:106`).
    public const val FILES_SEARCH: String = "搜索文件"
    public const val FILES_WORKSPACE: String = "手机工作区"
    public const val FILES_NONE: String = "还没有文件"
    public const val FILES_NONE_HINT: String = "智能体做的文件会出现在这里。"
    public const val FILES_DEMO: String = "3D 示例"
    public const val FILES_DEMO_OPEN: String = "打开 3D 示例"

    // FilePreviewPage: the four bodies, the share action and the bottom bar
    // (`FilesPage.swift:303`–`:350`).
    public const val FILES_PREVIEW_GONE: String = "这个文件已经不在了。"
    public const val FILES_PREVIEW_GONE_HINT: String = "请使用分享功能打开此文件。"
    public const val FILES_PREVIEW_OUTSIDE: String = "这个页面不在任何工作区里"
    public const val FILES_PREVIEW_OUTSIDE_HINT: String =
        "页面预览以它所属的工作区目录为根；散落的文件请用文本或分享打开。"
    public const val FILES_PREVIEW_MISSING: String = "此文件已不在工作区中。"
    public const val FILES_PREVIEW_SHARE: String = "分享"
    public const val FILES_PREVIEW_DONE: String = "完成"
    public const val FILES_PREVIEW_NOTICE_HTML: String = "页面在本地 pdsh-page:// 源下运行；默认不出网。"
    public const val FILES_PREVIEW_NOTICE_8MIB: String =
        "文本预览限制为 8 MiB；可分享文件后用其他应用打开完整内容。"
    public const val FILES_PREVIEW_NOTICE_256KIB: String =
        "文本预览限制为 256 KiB。可分享文件后用其他应用打开完整内容。"
    public const val FILES_PREVIEW_NOTICE_LINES: String =
        "仅显示前 %d 行；可继续使用分享功能打开完整文件。"
    public const val FILES_PREVIEW_NOTICE_COPY: String =
        "当前显示本机物化副本；若刚有写入，请稍后刷新工作区。"
    public const val FILES_PREVIEW_READ_FAILED: String = "读取文件失败：%s"
    public const val FILES_PREVIEW_NO_SESSION: String = "没有当前会话，无法读取会话工作区。"
    public const val FILES_PREVIEW_UNSAFE: String = "此文件已不在安全的本机工作区快照中。请刷新工作区后重试。"

    // SessionActivityPage: the eight fixed sections and the failure disclosure
    // (`SessionActivityPage.swift:16`–`:148`).
    public const val ACTIVITY_SESSION_TITLE: String = "会话"
    public const val ACTIVITY_SESSION_INTRO: String = "查看此会话的计划、待办、目标和后台活动。"
    public const val ACTIVITY_PLAN_TITLE: String = "计划"
    public const val ACTIVITY_PLAN_MODE: String = "模式"
    public const val ACTIVITY_PLAN_ON: String = "已启用"
    public const val ACTIVITY_PLAN_OFF: String = "未启用"
    public const val ACTIVITY_PLAN_PENDING: String = "正在应用模式变更"
    public const val ACTIVITY_PLAN_NONE: String = "此会话尚未启用计划模式。"
    public const val ACTIVITY_TODOS_TITLE: String = "待办"
    public const val ACTIVITY_TODOS_EMPTY: String = "当前会话还没有待办事项。"
    public const val ACTIVITY_GOAL_TITLE: String = "目标"
    public const val ACTIVITY_GOAL_PHASE: String = "阶段"
    public const val ACTIVITY_GOAL_ROUNDS: String = "轮次"
    public const val ACTIVITY_GOAL_ROUNDS_VALUE: String = "%d / %d"
    public const val ACTIVITY_GOAL_PAUSE: String = "暂停目标"
    public const val ACTIVITY_GOAL_RESUME: String = "恢复目标"
    public const val ACTIVITY_GOAL_COMPLETE: String = "标记完成"
    public const val ACTIVITY_GOAL_NONE: String = "当前会话没有进行中的目标。"
    public const val ACTIVITY_SUBAGENTS_TITLE: String = "子智能体"
    public const val ACTIVITY_SUBAGENTS_EMPTY: String = "当前会话没有子智能体。"
    public const val ACTIVITY_SUBAGENT_INTERRUPT: String = "中断子智能体"
    public const val ACTIVITY_SCHEDULES_TITLE: String = "计划任务"
    public const val ACTIVITY_SCHEDULES_EMPTY: String = "当前会话没有计划任务。"
    public const val ACTIVITY_SCHEDULE_DELETE: String = "删除计划任务"
    public const val ACTIVITY_JOBS_TITLE: String = "后台作业"
    public const val ACTIVITY_JOBS_EMPTY: String = "当前会话没有后台作业。"
    public const val ACTIVITY_JOB_STOP: String = "停止后台作业"
    public const val ACTIVITY_SKILLS_TITLE: String = "技能目录"
    public const val ACTIVITY_SKILLS_EMPTY: String = "当前没有可用的技能信息。"
    public const val ACTIVITY_ERRORS_TITLE: String = "暂不可用"
    public const val ACTIVITY_ERRORS_DETAIL: String = "%s的详细原因"
    public const val ACTIVITY_REFRESH: String = "刷新"

    // The words a row's status/phase/todo state is inked with
    // (`SessionActivityPage.swift:210`–`:250`). A phase or status the baseline
    // cannot translate is shown as its raw value, never as a guessed label.
    public const val ACTIVITY_TODO_DONE: String = "已完成"
    public const val ACTIVITY_TODO_RUNNING: String = "进行中"
    public const val ACTIVITY_TODO_PENDING: String = "待办"
    public const val ACTIVITY_PHASE_ACTIVE: String = "进行中"
    public const val ACTIVITY_PHASE_PAUSED: String = "已暂停"
    public const val ACTIVITY_PHASE_BLOCKED: String = "受阻"
    public const val ACTIVITY_PHASE_COMPLETE: String = "已完成"
    public const val ACTIVITY_PHASE_FAILED: String = "失败"
    public const val ACTIVITY_STATUS_ACTIVE: String = "启用"
    public const val ACTIVITY_STATUS_PENDING: String = "等待中"
    public const val ACTIVITY_STATUS_RUNNING: String = "运行中"
    public const val ACTIVITY_STATUS_STOPPING: String = "正在停止"
    public const val ACTIVITY_STATUS_COMPLETE: String = "已完成"
    public const val ACTIVITY_STATUS_FAILED: String = "失败"
    public const val ACTIVITY_STATUS_CANCELLED: String = "已取消"
    public const val ACTIVITY_STATUS_PAUSED: String = "已暂停"
    public const val ACTIVITY_STATUS_UNKNOWN: String = "状态未知"

    // The four confirmations (`SessionActivityPage.swift:158`–`:189`).
    public const val ACTIVITY_CONFIRM_GOAL_PAUSE: String = "暂停当前目标？"
    public const val ACTIVITY_CONFIRM_GOAL_RESUME: String = "恢复当前目标？"
    public const val ACTIVITY_CONFIRM_GOAL_COMPLETE: String = "完成当前目标？"
    public const val ACTIVITY_CONFIRM_GOAL_MESSAGE: String = "此操作会更新当前会话的目标状态。"
    public const val ACTIVITY_CONFIRM_GOAL_PAUSE_ACTION: String = "暂停"
    public const val ACTIVITY_CONFIRM_GOAL_RESUME_ACTION: String = "恢复"
    public const val ACTIVITY_CONFIRM_GOAL_COMPLETE_ACTION: String = "标记完成"
    public const val ACTIVITY_CONFIRM_SCHEDULE: String = "删除此计划任务？"
    public const val ACTIVITY_CONFIRM_JOB: String = "停止此后台作业？"
    public const val ACTIVITY_CONFIRM_JOB_ACTION: String = "停止作业"
    public const val ACTIVITY_CONFIRM_SUBAGENT: String = "中断此子 Agent？"
    public const val ACTIVITY_CONFIRM_SUBAGENT_ACTION: String = "中断"

    // PDSHShellPage: the device card, the command list, the run form and the
    // limits (`PDSHShellPage.swift:23`–`:89`). Half-width commas are the
    // baseline's own punctuation and are kept verbatim.
    public const val SHELL_DEVICE_TITLE: String = "这台手机"
    public const val SHELL_STATUS: String = "状态"
    public const val SHELL_STATUS_UNLINKED: String = "未链接或未配置"
    public const val SHELL_NETWORK: String = "网络"
    public const val SHELL_NETWORK_UNAVAILABLE: String = "不可用"
    public const val SHELL_WORKSPACE: String = "工作区"
    public const val SHELL_WORKSPACE_UNSET: String = "未设置"
    public const val SHELL_WORKSPACE_FOLDERS: String = "%d 个文件夹"
    public const val SHELL_READ_ONLY: String = "这些命令在这台手机上跑,只能读不能写。"
    public const val SHELL_EMPTY: String = "还没接上命令"
    public const val SHELL_EMPTY_HINT: String = "先选一个工作文件夹,就会列出能用的命令。"
    public const val SHELL_RUN_TITLE: String = "运行命令"
    public const val SHELL_COMMAND: String = "命令"
    public const val SHELL_NEEDS_APP: String = "这个命令要连上 App 才能跑,现在跑不了。"
    public const val SHELL_WORKING_DIR: String = "工作目录"
    public const val SHELL_ARGUMENTS: String = "参数,每行一个"
    public const val SHELL_ARGUMENTS_PLACEHOLDER: String = "例如:--help\n文件名"
    public const val SHELL_RUN: String = "运行"
    public const val SHELL_CANCEL: String = "取消"
    /** PDSHShellPage's in-flight command action (`PDSHShellPage.swift:69`). */
    public const val SHELL_STOP_RUNNING: String = "停止运行"
    public const val SHELL_OUTPUT_TITLE: String = "输出"
    public const val SHELL_OUTPUT_EMPTY: String = "运行结果会显示在这里。"
    public const val SHELL_LIMITS_TITLE: String = "限制"
    public const val SHELL_LIMIT_TIMEOUT: String = "超时"
    public const val SHELL_LIMIT_TIMEOUT_VALUE: String = "%d 秒"
    public const val SHELL_LIMIT_OUTPUT: String = "输出上限"
    public const val SHELL_LIMIT_FILES: String = "文件数上限"
    public const val SHELL_LIMIT_FILE: String = "单文件上限"

    // ---------------------------------------------------------------------
    // N2 lane: SessionsPage's iOS baseline sections (drawer + the embedded
    // `SessionQueuePage`). Appended only: every entry above belongs to another
    // lane and is never rewritten. The literals are the baseline's own zh copy
    // (`examples/probe-app/PhoneDSHProbe/SessionsPage.swift`), including its
    // ASCII commas where the baseline has them, so the two platforms read the
    // same words.
    // ---------------------------------------------------------------------

    // Drawer: the new-session row and why it can be blocked.
    public const val SESSIONS_NEW_BLOCKED_ENGINE: String = "先启动本地引擎,才能新建会话。"
    public const val SESSIONS_NEW_BLOCKED_TURN: String = "这一轮跑完就能新建"

    // Drawer: the completely-empty block (no folder, no session, no archive).
    // The baseline's title is the same literal as `WORKSPACE_EMPTY`; that entry
    // belongs to the folder page and is reused instead of duplicated.
    public const val SESSIONS_EMPTY_WORKSPACE_HINT: String = "选一个文件夹,会话和文件都放在里面。"
    public const val SESSIONS_NEW_WORKSPACE: String = "新建工作文件夹"

    // Drawer: one workspace row and its overflow menu.
    public const val SESSIONS_ADD_WORKSPACE: String = "添加工作文件夹"
    public const val SESSIONS_WORKSPACE_NEW_SESSION: String = "在这里新建会话"
    public const val SESSIONS_WORKSPACE_RENAME: String = "重命名工作文件夹"
    public const val SESSIONS_WORKSPACE_DELETE: String = "删除工作文件夹"
    public const val SESSIONS_WORKSPACE_DELETE_CONFIRM: String = "删除「%s」?"
    public const val SESSIONS_WORKSPACE_DELETE_DETAIL: String = "里面的会话会留着,只是不再放在这个文件夹里。"
    public const val SESSIONS_WORKSPACE_NAME: String = "工作文件夹名称"
    public const val SESSIONS_WORKSPACE_NAME_FIELD: String = "名字"
    public const val SESSIONS_WORKSPACE_CREATE_DETAIL: String =
        "会在 DSH 工作区里新建同名文件夹并登记为工作文件夹。"
    public const val SESSIONS_WORKSPACE_COUNT: String = "· %d 个会话"
    public const val SESSIONS_WORKSPACE_SESSIONS_EMPTY: String = "还没有会话"
    public const val SESSIONS_WORKSPACE_SESSIONS_EMPTY_HINT: String = "点上面的「新建会话」开始。"
    public const val SESSIONS_WORKSPACE_DEFAULT: String = "工作文件夹"
    public const val SESSIONS_WORKSPACE_INDEXED: String = "工作文件夹 %d"
    public const val SESSIONS_WORKSPACE_UNNAMED: String = "未命名文件夹"
    public const val SESSIONS_WORKSPACE_UNKNOWN: String = "工作文件夹状态未知"
    public const val SESSIONS_WORKSPACE_UNKNOWN_HINT: String =
        "宿主没有报告工作文件夹，无法判断有没有"
    public const val SESSIONS_WORKSPACE_OPTIONS: String = "%s 的选项"
    public const val SESSIONS_WORKSPACE_A11Y: String = "%s，%d 个会话"
    public const val SESSIONS_WORKSPACE_EXPAND: String = "展开工作文件夹的会话"
    public const val SESSIONS_WORKSPACE_COLLAPSE: String = "收起工作文件夹的会话"

    // Drawer: the archived section and the two session actions.
    public const val SESSIONS_ARCHIVED: String = "已归档"
    public const val SESSIONS_ARCHIVED_EMPTY: String = "没有已归档的会话"
    public const val SESSIONS_ARCHIVED_EMPTY_HINT: String = "归档的会话会留在这里，随时可以恢复。"
    public const val SESSIONS_ARCHIVED_UNKNOWN: String = "已归档会话未知"
    public const val SESSIONS_ARCHIVED_UNKNOWN_HINT: String =
        "宿主没有报告已归档的会话，无法判断有没有"
    public const val SESSIONS_ARCHIVE: String = "归档会话"
    public const val SESSIONS_RESTORE: String = "恢复"
    public const val SESSIONS_SESSION_TITLE: String = "会话标题"
    public const val SESSIONS_CURRENT: String = "当前会话"

    // The embedded `SessionQueuePage`: one section per queued message.
    public const val SESSIONS_QUEUE_TITLE: String = "待处理队列"
    public const val SESSIONS_QUEUE_NEXT_TURN: String = "下一轮"
    public const val SESSIONS_QUEUE_CURRENT_STEP: String = "当前步骤"
    public const val SESSIONS_QUEUE_LOADING: String = "正在读取队列…"
    public const val SESSIONS_QUEUE_EMPTY: String = "没有在排队的消息"
    public const val SESSIONS_QUEUE_EMPTY_HINT: String = "发消息时选「排到下一轮」，它就会等在这里。"
    public const val SESSIONS_QUEUE_NO_TEXT: String = "（没有文本内容）"
    public const val SESSIONS_QUEUE_EDIT: String = "编辑"
    public const val SESSIONS_QUEUE_STEER: String = "设为当前引导"
    public const val SESSIONS_QUEUE_REMOVE: String = "移除"
    public const val SESSIONS_QUEUE_ERROR: String = "错误"
    public const val SESSIONS_QUEUE_EDIT_TITLE: String = "编辑队列消息"

    // N6 probe family: strings appended for the line-for-line mirror of
    // ProbesPage.swift / BackgroundPage.swift / ExportPage.swift /
    // DailyBriefPage.swift / TaskScreenPage.swift. Earlier constants stay
    // untouched (this file is append-only) even where the port no longer uses
    // them.
    public const val LOCKDOWN_ON: String = "Lockdown Mode 已开启 — 本地 harness 不可用"
    public const val LOCKDOWN_OFF: String = "Lockdown Mode 已关闭"
    public const val LOCKDOWN_UNKNOWN: String = "Lockdown Mode 未知"
    public const val LOCKDOWN_GLYPH_ON: String = "🔒"
    public const val LOCKDOWN_GLYPH_OFF: String = "🔓"
    public const val LOCKDOWN_GLYPH_UNKNOWN: String = "🔒?"

    public const val PROBES_ENVIRONMENT_NOTE: String =
        "下面每一行都由与 macOS PhoneDSHProbeTests 相同的探针实现产生，" +
            "移植到 iOS UI actor 的 ProbeKit。G0 门槛来自 PLAN §2.5 与 " +
            "spec/v1/budgets.md §4。"
    public const val PROBES_RUN_GROUP_MENU: String = "运行单个组"
    public const val PROBES_SECTION_ROWS_EMPTY: String = "探针记录"
    public const val PROBES_EMPTY_NOTE: String =
        "这次启动还没有跑过探针。记录只在运行后出现；设备上的数值在此之前保持为空。"
    public const val PROBES_VALUE_NONE: String = "—"
    public const val PROBES_NON_GATING_ROW: String = "不计入 G0"
    public const val PROBES_BOUND: String = "bound"
    public const val PROBES_GATING: String = "gating"
    public const val PROBES_ROW_THRESHOLD: String = "G0 %s：%s"
    public const val PROBES_ROW_MET: String = " · met=%s"
    public const val PROBES_CHIP_PASS: String = "PASS"
    public const val PROBES_CHIP_FAIL: String = "FAIL"
    public const val PROBES_CHIP_INFO: String = "INFO"

    public const val BACKGROUND_SECTION_MATRIX_CELL: String = "矩阵单元"
    public const val BACKGROUND_CONTINUED_PROCESSING: String = "持续处理窗口"
    public const val BACKGROUND_CONTINUED_PROCESSING_NOTE: String =
        "宿主会为这一格请求一个持续处理窗口；被系统拒绝时退回普通后台任务。" +
            "设备跑过并记录下 arm 之前，这一项记为未验证。"
    public const val BACKGROUND_REQUIRED_WINDOW: String = "要求的窗口"
    // `Picker("Required window")`'s two segment words (`BackgroundPage.swift:44-45`).
    public const val BACKGROUND_WINDOW_10MIN: String = "10 minutes (PLAN)"
    public const val BACKGROUND_WINDOW_60S: String = "60 seconds (UI check)"
    public const val BACKGROUND_REQUIRED_NOTE: String =
        "只有 10 分钟这一格满足 PLAN 矩阵；60 秒那次只是 UI 冒烟，导出为 PARTIAL。"
    public const val BACKGROUND_INSTRUCTION_BACKGROUND: String =
        "开始后按 Home（或上滑）。让 App 在后台待满要求的窗口，再打开它。" +
            "运行器离开时停放宿主，回来时恢复。"
    public const val BACKGROUND_INSTRUCTION_LOCK: String =
        "开始后用侧键锁屏。保持锁屏满要求的窗口，再解锁。" +
            "运行器把受保护数据通知记为锁屏信号；没有受保护数据的设备可能不会发出。"
    public const val BACKGROUND_CONTINUED_ON: String = "持续处理"
    public const val BACKGROUND_CONTINUED_OFF: String = "无持续处理"
    public const val BACKGROUND_SIMULATOR_NOTE: String =
        "模拟器运行会记为 environment=android-emulator；它不是设备证据。"

    public const val EXPORT_PREVIEW_NOTE: String =
        "写好的文件放进仓库的验收目录，文件名用日期和设备名。"

    public const val DAILY_BRIEF_SHARE_ACTION: String = "分享"
    public const val DAILY_BRIEF_ADD_SOURCE_BUTTON: String = "添加 RSS / Atom 来源"
    public const val DAILY_BRIEF_NEWSPAPER_GLYPH: String = "📰"
    public const val DAILY_BRIEF_SOURCE_UNREAD: String = "开关状态未知"

    public const val TASK_SCREEN_BRIGHTNESS_LABEL: String = "最低亮度：%s"
    public const val BACKGROUND_ARM: String = "arm"
    // N6 page-structure contract: the section titles and action labels the
    // baseline declares in English keep the baseline language (the contract
    // compares titles/labels, not their translation). The Chinese constants
    // above remain for the row copy and for callers that still use them.
    public const val PROBES_SECTION_ENVIRONMENT_EN: String = "Environment"
    public const val PROBES_SECTION_ROWS_EN: String = "Rows"
    public const val PROBES_SECTION_ROWS_COUNT_EN: String = "Rows ({model.probeRows.count})"
    public const val PROBES_SECTION_THRESHOLDS_EN: String = "G0 thresholds"
    public const val PROBES_ACTION_RESET_EN: String = "Reset"
    public const val PROBES_ACTION_RUN_ALL_EN: String = "Run all probes"
    public const val PROBES_ACTION_RUN_GROUP_EN: String = "Run one group"

    public const val BACKGROUND_SECTION_MATRIX_CELL_EN: String = "Matrix cell"
    public const val BACKGROUND_SECTION_RUN_EN: String = "Run"
    public const val BACKGROUND_SECTION_OBSERVATION_EN: String = "Observation"
    public const val BACKGROUND_SECTION_CELLS_EN: String = "Matrix results"
    public const val BACKGROUND_SECTION_TRANSITIONS_EN: String = "Transitions"
    public const val BACKGROUND_ACTION_START_EN: String = "Start cell"
    public const val BACKGROUND_ACTION_CANCEL_EN: String = "Cancel"
    public const val BACKGROUND_LABEL_SCENARIO_EN: String = "Scenario"
    public const val BACKGROUND_LABEL_CONTINUED_EN: String = "BGContinuedProcessingTask window"
    public const val BACKGROUND_LABEL_REQUIRED_EN: String = "Required window"

    public const val TASK_SCREEN_SECTION_EN: String = "Task screen"
    public const val TASK_SCREEN_SECTION_REPORT_EN: String = "Report"
    public const val TASK_SCREEN_ACTION_SHOW_EN: String = "Show black task screen"
    public const val DAILY_BRIEF_ADD_SOURCE_TITLE: String = "添加资讯来源"
    public const val DAILY_BRIEF_NAME_OPTIONAL: String = "名称（可选）"
    public const val DAILY_BRIEF_URL_PLACEHOLDER: String = "https://example.com/feed.xml"
    public const val DAILY_BRIEF_SOURCE_FOOTER: String =
        "只支持 HTTPS 的 RSS 或 Atom 地址；不会抓取本机或私网服务。"
    public const val DAILY_BRIEF_CANCEL: String = "取消"
    public const val DAILY_BRIEF_ADD: String = "添加"

    // ---------------------------------------------------------------------
    // N3 lane: ChatPage / composer / message rows, mirrored clause by clause
    // from `examples/probe-app/PhoneDSHProbe/ChatPage.swift` and
    // `NativeMessageRows.swift`. Appended only: the constants above belong to
    // other lanes and are never rewritten.
    // ---------------------------------------------------------------------

    // Page head (ChatPage.swift `chatHeader`, NativeShell.swift `RunStatusDot`).
    public const val RUN_STATUS_STARTED: String = "运行中"
    public const val RUN_STATUS_PARKED: String = "后台暂停"
    public const val RUN_STATUS_STOPPED: String = "未启动"
    public const val HEADER_DRAWER: String = "打开会话列表"
    public const val HEADER_RUN_STATUS: String = "运行状态"
    public const val HEADER_MORE: String = "更多"
    public const val HEADER_EXPORT: String = "导出对话记录"
    public const val CHAT_EXPORT_CHOOSER: String = "分享对话记录"
    public const val CHAT_EXPORT_FAILED: String = "没有可用的分享应用，对话记录未导出。"
    public const val CHAT_EXPORT_TOO_LONG: String = "对话记录过长，且本机没有可用的文件分享通道，未导出。"
    public const val CHAT_EXPORT_TITLE_YOU: String = "你"
    public const val CHAT_EXPORT_TITLE_STEERING: String = "你（补充说明）"
    public const val CHAT_EXPORT_TITLE_DSH: String = "DSH"
    public const val CHAT_EXPORT_TITLE_TOOL_CALL: String = "工具调用"
    public const val CHAT_EXPORT_TITLE_TOOL_RESULT: String = "工具结果"
    public const val CHAT_EXPORT_TITLE_TOOL_ERROR: String = "工具错误"
    public const val CHAT_EXPORT_TITLE_CONTEXT: String = "上下文注入"
    public const val HEADER_SESSION_SETTINGS: String = "插件与工具"
    public const val SESSION_TITLE_NEW: String = "新会话"
    public const val SESSION_TITLE_CURRENT: String = "当前会话"
    public const val RENAME_DIALOG_TITLE: String = "重命名会话"
    public const val RENAME_FIELD: String = "会话名称"
    public const val RENAME_SAVE: String = "保存"

    // Failure surfaces (ChatPage.swift `errorBanner` / `failureLine`).
    public const val SEND_FAILED_LINE: String = "没发出去"
    public const val DOT_SEPARATOR: String = "·"
    public const val CLOSE_HINT: String = "关闭提示"

    // Markdown surface (NativeMarkdownBody.swift): an external link the OS cannot open.
    public const val MARKDOWN_LINK_OPEN_FAILED: String = "打不开这个链接"

    // Transcript chrome (ChatPage.swift `transcript`).
    public const val LOAD_EARLIER: String = "加载更早消息"
    public const val LOADING_EARLIER: String = "正在加载…"
    public const val TRANSCRIPT_CACHED: String = "显示上次对话 · 引擎后台启动中…"
    public const val BACK_TO_LATEST: String = "回到最新"

    // Empty states A/B/C (ChatPage.swift `emptyTimeline`).
    public const val ENGINE_NOT_STARTED: String = "引擎还没启动"
    public const val ENGINE_NOT_STARTED_HINT: String = "启动之后就能开始。"
    public const val START_ENGINE: String = "启动本地引擎"
    public const val STARTING_ENGINE: String = "正在启动…"
    public const val ENGINE_STATE_LABEL: String = "引擎状态"
    public const val ENGINE_STATE: String = "引擎状态"
    public const val ENGINE_STATE_STOPPED: String = "stopped"
    public const val ENGINE_STATE_STARTING: String = "starting"
    public const val ENGINE_STATE_RUNNING: String = "running"
    public const val ENGINE_STATE_RECOVERING: String = "recovering"
    public const val ENGINE_STATE_FAILED: String = "failed"
    public const val ENGINE_STATE_UNKNOWN: String = "unknown"
    public const val ENGINE_RESTART: String = "重新启动引擎"
    public const val ENGINE_RESTART_HINT: String = "上次启动失败后引擎不会自动重试。重新启动会确认这次失败并重新启动宿主，会话数据不受影响。"
    public const val PROVIDER_SETUP_TITLE: String = "还差一步:配好模型服务"
    public const val PROVIDER_SETUP_HINT: String = "选一个模型服务,就能开始。"
    public const val PROVIDER_SETUP_ACTION: String = "去配置模型服务"
    public const val READY_TITLE: String = "Phone DSH"
    public const val READY_SUBTITLE: String = "运行在手机端的 DeepSeek Harness"

    // Injected context (NativeChatTimelineChrome.swift `NativeContextSourceGroup`).
    public const val CONTEXT_GROUP: String = "上下文"
    public const val CONTEXT_GROUP_COUNT: String = "· %d 条"
    public const val CONTEXT_SOURCE_APPROVAL: String = "你同意的"
    public const val CONTEXT_SOURCE_FILES: String = "读过的文件"
    public const val CONTEXT_SOURCE_COMMAND: String = "命令输出"
    public const val CONTEXT_SOURCE_SEARCH: String = "搜到的"
    public const val CONTEXT_COPY: String = "复制这条上下文"
    public const val CONTEXT_COPY_NAMED: String = "复制%s上下文"

    // System event rows (NativeMessageRows.swift `NativeSystemEventRow`). The
    // host's wire word ("error", "cancelled") is never shown; this is the table.
    public const val SYSTEM_EVENT_TURN: String = "回合事件"
    public const val SYSTEM_EVENT_TURN_FAILED: String = "回合出错"
    public const val SYSTEM_EVENT_TURN_CANCELLED: String = "回合已取消"
    public const val SYSTEM_EVENT_MAX_TOKENS: String = "上下文已满"
    public const val SYSTEM_EVENT_RETRY: String = "模型请求重试"
    public const val SYSTEM_EVENT_COMPACTION: String = "上下文整理"
    public const val SYSTEM_EVENT_HOST: String = "主机事件"

    // Changed-files card (NativeChangedFilesCard.swift:31-32, :78). The count and
    // the file name are the card's own data; the words are the baseline's.
    public const val CHANGED_FILES_TITLE: String = "已编辑 %d 个文件"
    public const val CHANGED_FILES_SINGLE: String = "已编辑 %s"
    public const val CHANGED_FILES_ALL: String = "全部 %d 个文件"
    public const val CHANGED_FILES_COLLAPSE: String = "收起"

    // Message actions (NativeMessageActions.swift) and attachments.
    public const val MESSAGE_COPY: String = "复制"
    public const val MESSAGE_COPIED: String = "已复制"

    // Code block chrome (`Components.swift:151-225`).
    public const val CODE_COPY_ACTION: String = "拷贝代码"
    public const val CODE_WRAP_OFF: String = "关闭自动换行"
    public const val CODE_WRAP_ON: String = "自动换行"
    public const val CODE_EXPAND_ALL: String = "展开全部 %d 行"
    public const val CODE_COLLAPSE: String = "收起"

    // Pending cards.
    public const val WAITING_AUTHORIZATION: String = "等待授权"
    public const val QUESTION_CARD_TITLE: String = "需要你的回答"
    public const val QUESTION_CUSTOM_ANSWER: String = "其他回答"
    public const val QUESTION_INPUT_ANSWER: String = "输入回答"
    public const val QUESTION_MULTIPLE_HINT: String = "可多选，也可以补充自定义回答。"
    public const val QUESTION_SUBMIT: String = "提交回答"

    // Goal bar (ChatPage.swift `goalBar`).
    public const val GOAL_PHASE_ACTIVE: String = "目标 · 进行中"
    public const val GOAL_PHASE_PAUSED: String = "目标 · 已暂停"
    public const val GOAL_PHASE_BLOCKED: String = "目标 · 已阻塞"
    public const val GOAL_PHASE_COMPLETE: String = "目标 · 已完成"
    public const val GOAL_CLEAR_TARGET: String = "清除目标"

    // Composer (ChatPage.swift `composer`).
    public const val COMPOSER_PLACEHOLDER_IDLE: String = "发消息或创建任务，/ 调用指令，@ 文件或对话"
    public const val COMPOSER_PLACEHOLDER_STEER: String = "补充当前任务…"
    public const val COMPOSER_PLACEHOLDER_QUEUE: String = "排入下一轮…"
    public const val COMPOSER_SEND_LABEL: String = "发送消息"
    public const val COMPOSER_SEND_LABEL_STEER: String = "补充当前任务"
    public const val COMPOSER_SEND_LABEL_QUEUE: String = "排入下一轮"
    public const val COMPOSER_STOP_LABEL: String = "停止执行"
    public const val COMPOSER_STOPPING: String = "正在停止"
    public const val COMPOSER_RUNNING: String = "正在执行"
    public const val COMPOSER_ADD_MENU: String = "添加指令、引用或附件"
    public const val COMPOSER_ADD_COMMAND: String = "调用指令"
    public const val COMPOSER_ADD_REFERENCE: String = "引用文件或对话"
    public const val COMPOSER_ADD_IMAGE: String = "添加图片"
    public const val COMPOSER_ADD_FILE: String = "添加文件（写入工作区）"
    public const val COMPOSER_TRUNCATED: String = "已截断到 8000 字。"
    public const val COMPOSER_STEER_ATTACHMENT: String = "补充说明不支持附带图片；请切换为“排入下一轮”或移除图片。"
    public const val COMPOSER_REMOVE_IMAGE: String = "移除图片 %s"
    public const val COMPOSER_SLASH_LOADING: String = "正在读取 DSH 命令…"
    public const val COMPOSER_SLASH_EMPTY: String = "没有匹配的命令"
    public const val COMPOSER_REFERENCE_EMPTY: String = "没有匹配的文件或对话"
    public const val COMPOSER_NOTICE_CLOSE: String = "关闭"
    public const val COMPOSER_NO_COMMAND: String = "没有这条命令：/%s"

    // Access-mode menu (ChatPage.swift `accessModeMenu`).
    public const val ACCESS_MODE_UNAVAILABLE: String = "暂不可用"
    public const val ACCESS_MODE_NONE: String = "没有可切换的权限。"
    public const val ACCESS_MODE_HEADER_ALLOW: String = "写之前不再问你"
    public const val ACCESS_MODE_HEADER_ASK: String = "每次写之前会先问你"
    public const val ACCESS_MODE_LABEL: String = "权限：%s"
    public const val ACCESS_MODE_TITLE_FALLBACK: String = "权限"
    public const val ACCESS_MODE_CONFIRM_TITLE: String = "切换权限？"
    public const val ACCESS_MODE_CONFIRM_OPEN: String = "开启「%s」？"
    public const val ACCESS_MODE_CONFIRM_MESSAGE: String = "之后改文件、跑命令都不再问你。"
    public const val ACCESS_MODE_CONFIRM_ACTION: String = "开启"

    // Model menu (ChatPage.swift `modelMenu`).
    public const val MODEL_UNAVAILABLE: String = "模型目录暂不可用"
    public const val MODEL_SECTION_EFFORT: String = "强度"
    public const val MODEL_SECTION_MODEL: String = "模型"
    public const val MODEL_DEFAULT_EFFORT: String = "默认强度"
    public const val MODEL_DEFAULT_EFFORT_DETAIL: String = "默认强度 · %s"
    public const val MODEL_LABEL: String = "选择模型"
    public const val MODEL_FALLBACK: String = "模型"
    public const val EFFORT_OFF: String = "关"
    public const val EFFORT_LOW: String = "低"
    public const val EFFORT_MEDIUM: String = "中"
    public const val EFFORT_HIGH: String = "高"
    public const val EFFORT_MAX: String = "最高"

    // -----------------------------------------------------------------------
    // Appended by the C2 lane. The baseline labels live in
    // `NativeShell.swift`'s `EgressAllowListPage` (443-731) and
    // `WorkspaceFoldersPage` (356, 376); each constant names the control it
    // mirrors so the two pages cannot drift into two wordings.
    // -----------------------------------------------------------------------

    // Egress allow list: the allow-all switch, the empty-table actions and the
    // add/delete flow (`NativeShell.swift:466`, `:470`, `:482`, `:512`, `:496`,
    // `:667`, `:670`, `:661`).
    public const val EGRESS_ALLOW_ALL_TOGGLE: String = "允许连任何网站"
    public const val EGRESS_ALLOW_ALL_FOOTER: String = "打开之后,下面这些地址就不起作用了。"
    public const val EGRESS_INACTIVE: String = "现在不起作用"
    public const val EGRESS_RESTORE_DEFAULTS: String = "恢复成默认的"
    public const val EGRESS_ADD_ADDRESS: String = "添加地址"
    public const val EGRESS_ADD: String = "添加"
    public const val EGRESS_DELETE_ADDRESS: String = "删除这个地址"
    public const val EGRESS_DELETE_CONFIRM: String = "删除这个地址？"
    public const val EGRESS_DELETE_DETAIL: String = "删掉之后,这个地址就连不上了。"
    public const val EGRESS_ADD_HINT: String = "只写域名,不用写 http://"
    public const val EGRESS_ADD_PROBLEM: String = "只写域名,例如 api.deepseek.com。"
    public const val EGRESS_ADD_DUPLICATE: String = "这个地址已经在名单里了"

    // Workspace folders: the empty state's call to action and the toolbar verb
    // (`NativeShell.swift:356` / `:376`).
    public const val WORKSPACE_ADD_FOLDER: String = "添加工作文件夹"
    public const val WORKSPACE_ADD: String = "添加"

    // -----------------------------------------------------------------------
    // Appended by the L5 lane: the three device-connector pages. The copy is the
    // iOS baseline's own wording (`NativeDeviceConnectionPage.swift`,
    // `NativeDeviceSessionPage.swift`, `SessionArtifactsPage.swift`), including the
    // two `ContentUnavailableView` bodies that state what this build does *not* do.
    // -----------------------------------------------------------------------

    // 设备连接 (`NativeDeviceConnectionPage.swift:33-118`). The page title stays
    // the baseline's English word: it is that sheet's navigation title too.
    public const val DEVICE_TITLE: String = "Device"
    public const val DEVICE_DONE: String = "完成"
    public const val DEVICE_SECTION_DEVICES: String = "真实连接设备"
    public const val DEVICE_SECTION_TRANSPORT: String = "传输能力"
    public const val DEVICE_TRANSPORT_FOOTER: String =
        "真实传输尚未实现。此页只展示已注入连接器发布的状态，不会主动发起扫描。"
    public const val DEVICE_TRANSPORT_NOT_PROVIDED: String = "未提供"
    public const val DEVICE_TRANSPORT_PROVIDED: String = "已提供"
    public const val DEVICE_CONNECTOR_UNAVAILABLE: String = "未接入设备连接器"
    public const val DEVICE_CONNECTOR_UNAVAILABLE_HINT: String =
        "当前版本不会扫描、配对或伪造在线设备。"
    public const val DEVICE_NO_DEVICES: String = "没有在线设备"
    public const val DEVICE_NO_DEVICES_HINT: String = "连接器尚未发布真实在线设备。"
    public const val DEVICE_BLUETOOTH_CONNECTOR: String = "蓝牙连接器"
    public const val DEVICE_LOCAL_NETWORK_CONNECTOR: String = "局域网连接器"
    public const val DEVICE_FORGET_MAPPING: String = "解除该设备的会话映射"
    public const val DEVICE_SOURCE_LABEL: String = "注入的连接器"
    public const val DEVICE_SOURCE_NONE: String = "无"
    public const val DEVICE_CONNECTOR_FAILED: String = "连接器报告失败：%s"
    public const val DEVICE_OPEN_FAILED_UNAVAILABLE: String =
        "打不开这个设备的会话：没有可用的会话来源。"
    public const val DEVICE_OPEN_FAILED_MISMATCH: String =
        "保存的会话是 %s，但打开的是 %s；映射没有改动。"
    public const val DEVICE_OPEN_FAILED: String = "打不开这个设备的会话：%s"

    // 设备会话 (`NativeDeviceSessionPage.swift:362-441`).
    public const val DEVICE_SESSION_TITLE: String = "设备会话 · 只读监视"
    public const val DEVICE_SESSION_READ_EARLIER: String = "读取更早消息"
    public const val DEVICE_SESSION_READING_EARLIER: String = "正在读取…"
    public const val DEVICE_SESSION_LOADING: String = "正在读取设备会话…"
    public const val DEVICE_SESSION_EMPTY: String = "还没有交互记录"
    public const val DEVICE_SESSION_EMPTY_HINT: String =
        "设备与这个固定 Session 的真实交互会显示在这里。"
    public const val DEVICE_SESSION_READ_ONLY: String = "只读监视，请在设备上处理输入与确认"
    public const val DEVICE_SESSION_READ_FAILED: String = "读取设备会话失败：%s"
    public const val DEVICE_SESSION_NO_PROGRESS: String = "设备会话历史没有前进到 seq %s 之前。"
    public const val DEVICE_TOOL_INPUT: String = "输入"
    public const val DEVICE_TOOL_OUTPUT: String = "输出"
    public const val DEVICE_TOOL_WAITING: String = "等待工具结果"
    public const val DEVICE_TOOL_RUNNING: String = "运行中"
    public const val DEVICE_TOOL_DONE: String = "已完成"
    public const val DEVICE_TOOL_FAILED: String = "失败"
    public const val DEVICE_TOOL_STOPPED: String = "已停止"
    public const val DEVICE_IMAGE: String = "图片"
    public const val DEVICE_FILE: String = "文件"
    public const val DEVICE_DEVICE_LABEL: String = "设备"
    public const val DEVICE_CONTEXT_LABEL: String = "设备上下文"
    public const val DEVICE_REASONING_LABEL: String = "思考"

    // 本会话产物 (`SessionArtifactsPage.swift:31-188`).
    public const val ARTIFACTS_TITLE: String = "本会话产物"
    public const val ARTIFACTS_LOADING: String = "正在读取产物…"
    public const val ARTIFACTS_EMPTY_TITLE: String = "本会话 还没有已确认归属的产物"
    public const val ARTIFACTS_EMPTY_HINT: String =
        "此会话生成或导入的文件会显示在这里。没有真实会话来源的记录不会被归入本会话。"
    public const val ARTIFACTS_SECTION_SESSION: String = "本会话"
    public const val ARTIFACTS_SECTION_UNASSIGNED: String = "未归属"
    public const val ARTIFACTS_UNASSIGNED_FOOTER: String =
        "这些记录没有当前会话的真实来源信息，不计为本会话产物。"
    public const val ARTIFACTS_LOAD_FAILED: String = "无法读取产物：%s"
    public const val ARTIFACTS_OPEN_FAILED: String = "无法打开产物"
    public const val ARTIFACTS_MISSING_FILE: String = "文件已不在本机产物存储中。"
    public const val ARTIFACTS_NO_PREVIEW: String = "此文件无法预览"
    public const val ARTIFACTS_NO_PREVIEW_HINT: String = "可通过系统分享用其他应用打开。"
    // The open-failure alert's single button (`SessionArtifactsPage.swift:108`,
    // `role: .cancel`).
    public const val ARTIFACTS_ACKNOWLEDGE: String = "好"
    // L81: the workspace-backed store's one extra read state. The workspace tree is
    // created by the first write into it, so "not there yet" is a waiting state with
    // a retry, never "this session produced nothing".
    public const val ARTIFACTS_NO_WORKSPACE: String =
        "宿主还没有可读的工作区；第一轮写入后这里会列出产物。"
    // -----------------------------------------------------------------------
    // L14 lane: the three B-group pages (appended, never reordered).
    // -----------------------------------------------------------------------

    // Agent 预设 (`NativeAgentPresetsPage.swift`).
    public const val AGENT_PRESETS_TITLE: String = "Agent 预设"
    public const val AGENT_PRESETS_CREATE: String = "让 Agent 创建预设"
    public const val AGENT_PRESETS_CREATE_NOTE: String =
        "进入创造模式但不自动发送任务，现有草稿会保留。"
    public const val AGENT_PRESETS_CREATE_NOTE_BUILTIN: String =
        "可创建使用手机内建工具的本地 Agent 预设。外部套件与新 JavaScript 插件需使用桌面 DSH。"
    public const val AGENT_PRESETS_CREATE_UNAVAILABLE: String =
        "宿主没有可用的新建会话动作，无法进入创造模式。"
    public const val AGENT_PRESETS_CREATOR_UNAVAILABLE_PREFIX: String = "创造模式当前不可用："
    public const val AGENT_PRESETS_CREATOR_MISSING: String = "当前引擎没有提供创造模式预设。"
    public const val AGENT_PRESETS_LOADING: String = "正在读取预设…"
    public const val AGENT_PRESETS_UNREAD: String = "宿主还没有返回预设清单，暂不判断有没有预设。"
    public const val AGENT_PRESETS_EMPTY: String = "当前引擎没有预设。"
    public const val AGENT_PRESETS_DEFAULT: String = "默认"
    public const val AGENT_PRESETS_CUSTOM: String = "自定义"
    public const val AGENT_PRESETS_VIEW_CONFIG: String = "查看配置"
    public const val AGENT_PRESETS_USE_PRESET: String = "使用预设"
    public const val AGENT_PRESETS_DEFAULT_LOCKED: String = "默认已锁定"
    public const val AGENT_PRESETS_DEFAULT_READ_ONLY_REASON: String =
        "默认预设由此 Worker 的启动配置锁定。可用“使用预设”创建指定预设的新会话。"
    public const val AGENT_PRESETS_RELOAD: String = "重新读取"
    public const val AGENT_PRESETS_PRESET_GONE: String = "这个预设已不可用，请刷新后重试。"
    public const val AGENT_PRESETS_SESSION_FAILED: String = "会话没有创建成功，请稍后重试。"
    @Deprecated("The roster verb is 使用预设 (the PR26 iOS rename).", ReplaceWith("AGENT_PRESETS_USE_PRESET"))
    public const val AGENT_PRESETS_MAKE_DEFAULT: String = AGENT_PRESETS_USE_PRESET

    // 已加载插件 (`NativePluginInventoryPage.swift`).
    public const val PLUGIN_INVENTORY_TITLE: String = "已加载插件"
    /** Destination title from NativeConfigurationPage; retained for callers. */
    public const val PLUGIN_INVENTORY_CONFIG: String = "插件与工具"
    @Deprecated("The source inventory page has no separate read-only CTA row.")
    public const val PLUGIN_INVENTORY_READ_ONLY: String =
        "这台手机没有 pnpm、execa 或子进程安装环境。插件和 bundle 可以在这里查看；安装、启用和停用请在桌面 DSH 完成。"
    @Deprecated("The source inventory page is an untitled list section.")
    public const val PLUGIN_INVENTORY_SECTION: String = "插件列表"
    public const val PLUGIN_INVENTORY_SEARCH: String = "搜索插件"
    public const val PLUGIN_INVENTORY_LOADING: String = "正在读取插件…"
    public const val PLUGIN_INVENTORY_EMPTY: String = "没有匹配的插件。"
    public const val PLUGIN_INVENTORY_UNREAD: String = "宿主还没有返回插件清单，暂不判断有没有插件。"
    public const val PLUGIN_INVENTORY_ENTRY: String = "条目"
    public const val PLUGIN_INVENTORY_MODULE: String = "模块"
    public const val PLUGIN_INVENTORY_ENABLED: String = "启用"
    public const val PLUGIN_INVENTORY_PHASE: String = "运行状态"
    public const val PLUGIN_INVENTORY_YES: String = "是"
    public const val PLUGIN_INVENTORY_NO: String = "否"
    public const val PLUGIN_INVENTORY_MANAGEMENT_NOTICE: String =
        "这台手机没有 pnpm、execa 或子进程安装环境。插件和 bundle 可以在这里查看；安装、启用和停用请在桌面 DSH 完成。"

    // 手机权限 (`PhonePermissionsPage.swift`, `CapabilityStatus.swift`).
    public const val PHONE_PERMISSIONS_TITLE: String = "手机权限"
    public const val PHONE_PERMISSIONS_AUDIT_SECTION: String = "最近使用审计"
    public const val PHONE_PERMISSIONS_AUDIT_EMPTY: String = "暂无使用记录"
    public const val PHONE_PERMISSIONS_AUDIT_UNKNOWN: String = "宿主没有报告使用审计，暂不判断有没有记录。"
    public const val PHONE_PERMISSIONS_CONFIRM_TITLE: String = "允许使用这项能力？"
    public const val PHONE_PERMISSIONS_CONTINUE: String = "继续"
    public const val PHONE_PERMISSIONS_DISABLE_TITLE: String = "已停用应用内使用"
    public const val PHONE_PERMISSIONS_DISABLE_BODY: String =
        "这只停用 Phone DSH 的%s能力，不会撤销系统权限。撤销或修改系统授权请前往系统设置。"
    public const val PHONE_PERMISSIONS_DISABLE_ACK: String = "知道了"
    public const val PHONE_PERMISSIONS_OPEN_SETTINGS: String = "去系统设置"
    public const val PHONE_PERMISSIONS_MANAGE_PHOTOS: String = "管理可访问照片"
    public const val PHONE_PERMISSIONS_STATUS_NOT_DETERMINED: String = "未请求"
    public const val PHONE_PERMISSIONS_STATUS_AUTHORIZED: String = "已允许"
    public const val PHONE_PERMISSIONS_STATUS_LIMITED: String = "部分允许（%d）"
    public const val PHONE_PERMISSIONS_STATUS_DENIED: String = "已拒绝"
    public const val PHONE_PERMISSIONS_STATUS_RESTRICTED: String = "受系统限制"
    public const val PHONE_PERMISSIONS_STATUS_REQUESTED: String = "已请求（系统不告知是否被拒）"
    public const val PHONE_PERMISSIONS_STATUS_UNAVAILABLE: String = "当前设备不可用"
    public const val PHONE_PERMISSIONS_STATUS_ALWAYS_ON: String = "常开"
    public const val PHONE_PERMISSIONS_STATUS_LOCAL_NETWORK_UNVERIFIED: String = "未验证 · 点击测试"
    public const val PHONE_PERMISSIONS_STATUS_LOCAL_NETWORK_DENIED: String = "可能已拒绝"
    public const val PHONE_PERMISSIONS_STATUS_BIOMETRIC_CONFIRM: String = "已允许 · 写操作前确认"
    public const val PHONE_PERMISSIONS_BIOMETRIC_UNAVAILABLE: String = "此宿主未提供面容确认，开关不可用"
    public const val PHONE_PERMISSIONS_APP_SWITCH_UNAVAILABLE: String = "此宿主由系统授权决定，暂无应用内开关"

    // ---------------------------------------------------------------------
    // L13 lane: the three iOS pages Android did not carry
    // (`chat-preferences`, `native-settings-document`, `native-shortcuts`).
    // Every literal below is the Swift page's own wording at iOS HEAD; the
    // picker/row labels are also the contract's section titles and action
    // labels, so they are declared once here and read by both the page and the
    // contract checker's resolver.
    // ---------------------------------------------------------------------

    // 聊天外观 (`ChatPreferencesPage.swift:76`).
    public const val CHAT_PREFERENCES_TITLE: String = "聊天外观"
    public const val CHAT_PREFERENCES_SECTION_APPEARANCE: String = "外观"
    public const val CHAT_PREFERENCES_SECTION_FONT: String = "字号"
    public const val CHAT_PREFERENCES_SECTION_COLLAPSE: String = "过程折叠"
    public const val CHAT_PREFERENCES_SECTION_TRANSCRIPT: String = "转录"
    public const val CHAT_PREFERENCES_ROW_APPEARANCE: String = "外观"
    public const val CHAT_PREFERENCES_ROW_FONT_TEXT: String = "正文"
    public const val CHAT_PREFERENCES_ROW_FONT_CODE: String = "代码"
    public const val CHAT_PREFERENCES_ROW_COLLAPSE: String = "折叠时机"
    public const val CHAT_PREFERENCES_ROW_TRANSCRIPT: String = "转录密度"
    public const val CHAT_PREFERENCES_APPEARANCE_SYSTEM: String = "跟随系统"
    public const val CHAT_PREFERENCES_APPEARANCE_LIGHT: String = "浅色"
    public const val CHAT_PREFERENCES_APPEARANCE_DARK: String = "深色"
    public const val CHAT_PREFERENCES_COLLAPSE_COMPLETION: String = "完成时"
    public const val CHAT_PREFERENCES_COLLAPSE_NEXT_INPUT: String = "下一条消息"
    public const val CHAT_PREFERENCES_DENSITY_COMPACT: String = "紧凑"
    public const val CHAT_PREFERENCES_DENSITY_STANDARD: String = "标准"
    public const val CHAT_PREFERENCES_DENSITY_DETAILED: String = "详细"
    public const val CHAT_PREFERENCES_DENSITY_VERBOSE: String = "完整"
    public const val CHAT_PREFERENCES_FOOTER_APPEARANCE: String =
        "深色仍在适配中；默认浅色与官方 402pt 基线一致。"
    public const val CHAT_PREFERENCES_FOOTER_FONT: String =
        "正文字号作用于消息正文；代码字号作用于代码块与工具详情。"
    public const val CHAT_PREFERENCES_FOOTER_COLLAPSE: String = "与页头 more 菜单中的选择同步。"
    public const val CHAT_PREFERENCES_FONT_SIZE_FORMAT: String = "%dpt"
    public const val CHAT_PREFERENCES_STEPPER_DECREASE: String = "减小"
    public const val CHAT_PREFERENCES_STEPPER_INCREASE: String = "增大"

    // 配置文件 (`NativeSettingsDocumentPage.swift:12-31`).
    public const val SETTINGS_DOCUMENT_TITLE: String = "配置文件"
    public const val SETTINGS_DOCUMENT_REDACTION_NOTE: String =
        "仅显示 DSH 已脱敏的设置描述与 revision；密钥和本机路径不会出现在这里。"
    public const val SETTINGS_DOCUMENT_LOADING: String = "正在读取配置…"
    public const val SETTINGS_DOCUMENT_EMPTY: String = "DSH 没有可显示的自定义设置"
    public const val SETTINGS_DOCUMENT_UNKNOWN: String = "读取不到脱敏配置"
    public const val SETTINGS_DOCUMENT_UNKNOWN_HINT: String = "宿主尚未提供设置描述，这里不显示编造的内容。"
    public const val SETTINGS_DOCUMENT_FAILED: String = "读取配置失败：%s"
    public const val SETTINGS_DOCUMENT_READ_ONLY: String = "只读：内容来自宿主的脱敏快照，不能在这里编辑。"
    public const val SETTINGS_DOCUMENT_SHARE: String = "导出脱敏配置"
    public const val SETTINGS_DOCUMENT_SHARE_UNAVAILABLE: String = "宿主未提供系统分享，内容只能在本页查看。"

    // 快捷键 (`NativeShortcutsPage.swift:29-31`).
    public const val SHORTCUTS_TITLE: String = "快捷键"
    public const val SHORTCUTS_SECTION_COMMANDS: String = "应用命令"
    public const val SHORTCUTS_SECTION_FIXED: String = "固定输入操作（只读）"
    public const val SHORTCUTS_ACTION_SEND: String = "发送消息"
    public const val SHORTCUTS_ACTION_ALTERNATE: String = "另一种发送行为"
    public const val SHORTCUTS_ACTION_STOP: String = "停止当前回复"
    public const val SHORTCUTS_ACTION_SETTINGS: String = "打开设置"
    public const val SHORTCUTS_ACTION_SHORTCUTS: String = "打开快捷键速查"
    public const val SHORTCUTS_ACTION_LATEST: String = "回到最新"
    public const val SHORTCUTS_FIXED_NEW_LINE: String = "换行"
    public const val SHORTCUTS_FIXED_SEND: String = "发送"
    public const val SHORTCUTS_FIXED_ALTERNATE: String = "另一种发送行为"
    public const val SHORTCUTS_FIXED_NEW_LINE_KEYS: String = "⇧↩"
    public const val SHORTCUTS_FIXED_SEND_KEYS: String = "↩"
    public const val SHORTCUTS_FIXED_ALTERNATE_KEYS: String = "⌘↩"
    public const val SHORTCUTS_RESET_ALL: String = "恢复全部默认"
    public const val SHORTCUTS_UNKNOWN_HINT: String = "宿主没有报告快捷键存储，这里不显示默认绑定。"
    public const val SHORTCUTS_READ_ONLY_HINT: String = "快捷键由宿主读写；本页只显示当前绑定，编辑入口尚未接入。"

    // ---------------------------------------------------------------------
    // L18 lane: the two MCP pages as the iOS HEAD `86a39aac` contract states
    // them (`spec/ui/v1/pages/mcp-settings.json`, `mcp-editor.json`), which is
    // `MCPSettingsPage.swift` in the probe app. Appended only: every entry
    // above belongs to another lane and is never rewritten.
    // ---------------------------------------------------------------------

    // The list's one titled group (`MCPSettingsPage.swift:46`) and its footer
    // (`:69`). The rows, the empty/loading/unavailable states and the fold stay
    // the page's own; the title is the baseline's.
    public const val MCP_LIST_SECTION: String = "Streamable HTTP MCP"
    public const val MCP_LIST_FOOTER: String =
        "每个服务器只放行它自己的地址和端口。这里填的授权和密钥只留在本机；模型和搜索用的密钥不会拿来给服务器用。"

    // 操作 (`MCPSettingsPage.swift:83`): 刷新注册表 (`:87`) and 添加 MCP 服务器
    // (`:93`, the same copy as the editor's own title at `:266`).
    public const val MCP_ACTION_SECTION: String = "操作"
    public const val MCP_ACTION_REFRESH: String = "刷新注册表"
    public const val MCP_ACTION_ADD_SERVER: String = "添加 MCP 服务器"

    // 局域网设备 (`MCPSettingsPage.swift:101`): the group, its scan verb and the
    // iOS toggle 停止扫描 (`:102`), the status line (`:105`, page-owned words for
    // the host's LanScanStatus) and the unverified note (`:117`, iOS copy). The
    // discovery rules are `spec/device/v1/lan-mcp.md`; a candidate is never a grant.
    public const val MCP_LAN_SECTION: String = "局域网设备"
    public const val MCP_LAN_SCAN: String = "扫描局域网设备"
    public const val MCP_LAN_STOP: String = "停止扫描"
    public const val MCP_LAN_STATUS_IDLE: String = "点击扫描局域网设备"
    public const val MCP_LAN_STATUS_UNAVAILABLE: String = "本宿主未接入局域网发现"
    public const val MCP_LAN_STATUS_SCANNING: String = "正在扫描局域网设备"
    public const val MCP_LAN_STATUS_FOUND: String = "选择设备并确认地址与凭证"
    public const val MCP_LAN_STATUS_NONE: String = "未发现设备，可重新扫描或手动添加"
    public const val MCP_LAN_STATUS_EXPIRED: String = "扫描结果已过期，请重新扫描"
    public const val MCP_LAN_STATUS_NO_WIFI: String = "未连接 Wi-Fi，无法扫描局域网设备；可手动添加"
    public const val MCP_LAN_STATUS_FAILED: String = "局域网扫描失败，可重新扫描或手动添加"
    public const val MCP_LAN_UNVERIFIED: String = "未验证"
    public const val MCP_LAN_NOTE: String = "发现结果尚未验证。请核对设备地址并输入设备提供的授权凭证。"

    // The editor's two titled groups: 服务器 (`MCPSettingsPage.swift:188`, the form)
    // and 认证头与设备密钥 (`:203`, the header list) with its footer (`:229`).
    public const val MCP_SECTION_SERVER: String = "服务器"
    public const val MCP_SECTION_AUTH: String = "认证头与设备密钥"
    public const val MCP_AUTH_FOOTER: String =
        "值只写入本机应用私有存储；设备支持时使用 Android Keystore 加密。不会写进配置文件，也不会进日志。留空就是保留已经存过的值。"

    // The editor's header rows and the two verbs that add and delete them
    // (`MCPSettingsPage.swift:206,209,213,224,260`).
    public const val MCP_ACTION_ADD_HEADER: String = "添加认证头"
    public const val MCP_ACTION_DELETE_SERVER: String = "删除并撤销授权与密钥"
    public const val MCP_REMOVE_HEADER: String = "移除这个认证头"
    public const val MCP_FIELD_HEADER_NAME: String = "Header，例如 Authorization"
    public const val MCP_FIELD_HEADER_ENV: String = "环境变量名（可留空自动生成）"
    public const val MCP_FIELD_HEADER_VALUE: String = "认证值（只写入应用私有存储）"
    public const val MCP_FIELD_HEADER_VALUE_STORED: String = "已保存；留空保持不变"
    public const val MCP_FIELD_HEADER_HINT: String = "留空这一行不会覆盖已经存过的值"

    // 工具调用超时 (`MCPSettingsPage.swift:199`): a number the host executes with,
    // so an empty field means the host's own default rather than a zero here.
    public const val MCP_FIELD_TIMEOUT: String = "工具调用超时（毫秒）"
    public const val MCP_FIELD_TIMEOUT_PLACEHOLDER: String = "留空使用宿主默认值"
    public const val MCP_FIELD_TIMEOUT_HINT: String = "以毫秒计；留空表示不改宿主的默认超时"
    public const val MCP_DELETE_HINT: String = "删除会一并撤销这条服务器的精确授权和设备密钥"

    // ---------------------------------------------------------------------
    // L21 lane: the probes record count. `ProbesPage.swift:112` renders
    // `PageSection("Rows (\(model.probeRows.count))")` — a fixed template plus one
    // measured number — so the copy keeps a `%d` slot and the page formats the
    // count. `PROBES_SECTION_ROWS_COUNT_EN` above is the literal copy of the Swift
    // interpolation source, which the page must never render. Appended only.
    // ---------------------------------------------------------------------
    public const val PROBES_SECTION_ROWS_COUNT: String = "Rows (%d)"

    // ---------------------------------------------------------------------
    // L16 lane: `NativeConfigurationPage`'s missing contract controls
    // (`spec/ui/v1/pages/native-configuration.json`, iOS HEAD `86a39aac`).
    //
    // The section titles and verbs are the baseline's, with one deliberate
    // copy divergence: the baseline's section is "iPhone Worker 限制". This
    // page runs on an Android phone, so it says 手机 Worker 限制 — printing
    // "iPhone" here would be a false statement about the device (the same rule
    // `NativePluginInventoryPage` follows for its management sentence).
    //
    // The two prose constants below are the baseline's own wording; the
    // limitation *sentence* is not copied: the host's measured sentence (or
    // `PLUGIN_INVENTORY_MANAGEMENT_NOTICE`) is shown instead.
    // ---------------------------------------------------------------------
    public const val CONFIGURATION_BUILT_IN_SECTION: String = "内置插件设置"
    public const val CONFIGURATION_SCOPE_SECTION: String = "本机管理范围"
    public const val CONFIGURATION_LIMITS_SECTION: String = "手机 Worker 限制"
    public const val CONFIGURATION_SCOPE_TEXT: String =
        "这一页显示引擎里真正装着的插件。保存后马上生效。"
    public const val CONFIGURATION_ONLY_LOADED_TEXT: String =
        "只有真正加载起来的插件才会显示为已启用。没装的,这里不会假装它在跑。"
    public const val CONFIGURATION_SAVE: String = "保存"
    public const val CONFIGURATION_SAVE_DEFAULT: String = "保存默认"
    public const val CONFIGURATION_DISCARD: String = "撤销"
    public const val CONFIGURATION_RESET: String = "恢复默认"
    public const val CONFIGURATION_INSTALL_THIRD_PARTY: String = "安装第三方插件"
    public const val CONFIGURATION_CREATE_WITH_AGENT: String = "让 Agent 创建插件"
    // ---------------------------------------------------------------------
    // L15 lane: the 2026-11-01 iOS contract for the two pages whose structure
    // changed at `86a39aac` (PR #13). The model-provider page gained the
    // contract's 生效方式 group and the editor's per-model rows, and the
    // web-search page became a mode/address/key page. Appended only: the copy
    // table is one file per lane, and every label the contract compares is
    // quoted verbatim (`添加模型服务` / `编辑默认服务` / `启动本地引擎` / `删除 %@`).
    // ---------------------------------------------------------------------
    public const val PROVIDER_ADD_SERVICE: String = "添加模型服务"
    public const val PROVIDER_EDIT_DEFAULT: String = "编辑默认服务"
    public const val PROVIDER_SECTION_APPLY: String = "生效方式"
    public const val PROVIDER_START_ENGINE: String = "启动本地引擎"
    public const val PROVIDER_RESTART_HINT_IDLE: String = "配置会在下次启动主机时生效。"
    public const val PROVIDER_RESTART_HINT_RUNNING: String = "保存已落盘。新的服务和模型在下一次启动 App 时装配进引擎——停止并重启主机不会重读配置（引擎的环境在进程启动时就建好了）。"
    public const val PROVIDER_EDIT: String = "编辑"
    public const val PROVIDER_DELETE: String = "删除"
    public const val PROVIDER_DELETE_CONFIRM_TITLE: String = "删除模型服务？"
    public const val PROVIDER_DELETE_CONFIRM_TEXT: String = "会删掉这个服务的配置,以及存在这台手机上的密钥。"
    // iOS spells this `String(format: "删除 %@", name)`; Kotlin's `String.format`
    // has no Object conversion, so the template carries `%s` and renders the same
    // sentence (`删除 DeepSeek`). The argument is a name, never a key.
    public const val PROVIDER_DELETE_NAMED: String = "删除 %s"
    public const val PROVIDER_EDITOR_EDIT_TITLE: String = "编辑模型服务"
    public const val PROVIDER_MODEL_CATALOG: String = "模型目录"
    public const val PROVIDER_KEY_SECTION: String = "密钥"
    public const val PROVIDER_FIELD_NAME: String = "显示名称"
    public const val PROVIDER_FIELD_ID: String = "标识"
    public const val PROVIDER_FIELD_ID_NEW: String = "标识（留空自动生成）"
    public const val PROVIDER_FIELD_URL: String = "服务 URL"
    public const val PROVIDER_DEFAULT_MODEL: String = "默认模型"
    public const val PROVIDER_REASONING_EFFORT: String = "推理强度"
    public const val PROVIDER_EFFORT_OFF: String = "关闭"
    public const val PROVIDER_EFFORT_LOW: String = "低"
    public const val PROVIDER_EFFORT_HIGH: String = "高"
    public const val PROVIDER_EFFORT_MAX: String = "最高"
    public const val PROVIDER_TEXT_INPUT: String = "文本输入"
    public const val PROVIDER_IMAGE_INPUT: String = "图片输入"
    public const val PROVIDER_DELETE_MODEL: String = "删除这个模型"
    public const val PROVIDER_ADD_MODEL: String = "添加模型"
    public const val PROVIDER_MODEL_ID: String = "模型 ID"
    public const val PROVIDER_IMPORT_CLIPBOARD: String = "粘贴密钥"
    public const val PROVIDER_DELETE_SAVED_KEY: String = "删除已保存的密钥"
    public const val PROVIDER_SAVING: String = "保存中…"
    public const val PROVIDER_KEY_FIELD: String = "API 密钥"
    public const val PROVIDER_KEY_FIELD_REPLACE: String = "输入新密钥以替换"
    public const val PROVIDER_KEY_SAVED_LINE: String = "此设备已保存密钥"
    public const val PROVIDER_KEY_NONE_LINE: String = "尚未保存密钥"
    public const val PROVIDER_KEY_UNREADABLE_LINE: String = "无法读取此设备的密钥"
    public const val PROVIDER_KEY_STORE_HINT: String = "密钥只存在这台手机上,手机解锁过一次之后才读得到。配置、日志、网页里都没有它。"
    public const val PROVIDER_PROTOCOL_ANTHROPIC: String = "地址以 /anthropic 结尾：使用 Anthropic Messages（请求 /v1/messages，密钥走 x-api-key）。"
    public const val PROVIDER_PROTOCOL_OPENAI: String = "按 OpenAI 兼容协议请求 /chat/completions（密钥走 Authorization: Bearer）。"
    public const val PROVIDER_TEST: String = "测试"

    // Web search, same lane: the mode the page follows, the address, the key
    // state, and when a change applies. 保存 is the one button on the page; it is
    // drawn by the page's own button composable because the contract models that
    // button without a label (its visible text is the copy below).
    public const val WEB_SEARCH_SECTION_MODE: String = "用哪一份搜索"
    public const val WEB_SEARCH_MODE_FOLLOW: String = "用模型服务自带的"
    public const val WEB_SEARCH_MODE_FOLLOW_HINT: String = "自动用所选官方 DeepSeek 模型服务保存的密钥，不需要另填。"
    public const val WEB_SEARCH_MODE_API: String = "自己填一个"
    public const val WEB_SEARCH_MODE_API_HINT: String = "填地址和密钥,单独连一个搜索服务。"
    public const val WEB_SEARCH_FOLLOW_NO_PROFILE: String = "还没有设置模型服务。到「模型服务」选好官方 DeepSeek 并保存密钥后，搜索和抓取会自动启用。"
    public const val WEB_SEARCH_FOLLOW_SUPPORTED: String = "已自动沿用这个模型服务保存的密钥，搜索和抓取都可用。"
    public const val WEB_SEARCH_FOLLOW_UNSUPPORTED: String = "没有自动启用：需要官方 DeepSeek 模型服务且保存的密钥可读；独立搜索配置在本机不可用。"
    public const val WEB_SEARCH_FOLLOW_UNKNOWN: String = "读不到官方搜索是否启用，先重启本地引擎再确认。"
    public const val WEB_SEARCH_SECTION_ADDRESS: String = "地址"
    public const val WEB_SEARCH_ADDRESS_PLACEHOLDER: String = "api.deepseek.com"
    public const val WEB_SEARCH_ADDRESS_FOOTER: String = "照服务商给的那段整段粘过来就行。"
    public const val WEB_SEARCH_SECTION_KEY: String = "密钥状态"
    public const val WEB_SEARCH_KEY_LABEL: String = "密钥"
    public const val WEB_SEARCH_KEY_STORED: String = "存好了"
    public const val WEB_SEARCH_KEY_NOT_STORED: String = "还没存"
    public const val WEB_SEARCH_KEY_TAIL: String = "尾号 %s"
    public const val WEB_SEARCH_KEY_PLACEHOLDER: String = "粘贴密钥"
    public const val WEB_SEARCH_KEY_FOOTER: String = "这里只看得到尾巴四位,看不到密钥本身。密钥只存在这台手机上,不进配置、日志和报错。"
    public const val WEB_SEARCH_SAVE_KEY: String = "保存"
    public const val WEB_SEARCH_CLEAR_KEY: String = "清除密钥"
    public const val WEB_SEARCH_CLEAR: String = "清除"
    public const val WEB_SEARCH_CLEAR_TITLE: String = "清除密钥?"
    public const val WEB_SEARCH_CLEAR_TEXT: String = "清除之后这台手机就用不了模型,得重新粘一遍。"
    public const val WEB_SEARCH_DELETE_SERVICE: String = "删除这个搜索服务"
    public const val WEB_SEARCH_DELETE: String = "删除"
    public const val WEB_SEARCH_DELETE_FOOTER: String = "只改这台手机上的设置,不会立刻联网。"
    public const val WEB_SEARCH_DELETE_TITLE: String = "删除这个搜索服务?"
    public const val WEB_SEARCH_DELETE_TEXT: String = "地址和密钥都会删掉,搜索回到用模型服务自带的那份。"
    public const val WEB_SEARCH_SECTION_APPLY: String = "什么时候生效"
    public const val WEB_SEARCH_START_ENGINE: String = "启动本地引擎"
    public const val WEB_SEARCH_STOP_ENGINE: String = "停止本地引擎"
    public const val WEB_SEARCH_RESTART_HINT_IDLE: String = "下次启动本地引擎时才生效。"
    public const val WEB_SEARCH_RESTART_HINT_RUNNING: String = "重启本地引擎之后生效;工作文件夹和会话都不变。"
    public const val WEB_SEARCH_SECTION_WARNING: String = "需要处理"
    public const val WEB_SEARCH_WARNING_TAIL: String = "重启本地引擎之后这行提示会自己消失。"
    public const val WEB_SEARCH_SECTION_NOTES: String = "还要知道"
    public const val WEB_SEARCH_NOTE_MODEL: String = "沿用模型服务时，网页搜索和抓取共用官方 DeepSeek 模型密钥。"
    public const val WEB_SEARCH_NOTE_KEY: String = "密钥只存在这台手机上,本地引擎拿到的只是一个占位。"
    public const val WEB_SEARCH_NOTE_RESTART: String = "存好或删掉之后要重启本地引擎才生效;重启不会动你的文件夹和会话。"
    public const val WEB_SEARCH_FAILURE_KEY: String = "读取不到这台设备上的密钥"
    public const val WEB_SEARCH_COMMIT_SAVED: String = "存好了"
    public const val WEB_SEARCH_COMMIT_FAILED: String = "没存上，改一下再试"

    // The chat page-head menu's two session-scoped rows (`ChatPage.swift:256`,
    // `:260`). They are visible menu copy, not screen-reader strings.
    public const val HEADER_ARTIFACTS: String = "产物"
    public const val HEADER_WORKBENCH: String = "工作区"

    // -----------------------------------------------------------------------
    // L25 lane: the two embedded subpages of README §1's
    // 「内嵌子页随父页实现、不单独排期」 rule. Appended only: no entry above is
    // rewritten, and each block says which baseline page it ports.
    // -----------------------------------------------------------------------

    // ScheduleEditorPage (`NativeAutomationPage.swift:212`–`:420`): the form the
    // schedule catalog presents. Every literal is the baseline's own word, in its
    // own order — the two editor titles (`:278`), the two section titles (`:252`
    // `:258`), the 修改计划时间 toggle (`:260`), the 规则 picker's six options
    // (`:264`–`:269`), the six rule-field labels/placeholders (`:294`–`:310`) and
    // the six validation sentences (`:397`–`:406`).
    public const val AUTOMATION_EDITOR_NEW_TITLE: String = "新建自动化"
    public const val AUTOMATION_EDITOR_EDIT_TITLE: String = "编辑自动化"
    public const val AUTOMATION_EDITOR_CONTENT_SECTION: String = "任务内容"
    public const val AUTOMATION_EDITOR_TIMING_SECTION: String = "计划时间"
    public const val AUTOMATION_EDITOR_NAME_FIELD: String = "名称"
    // The second field reuses AUTOMATION_PROMPT (提醒内容): the baseline's form
    // and its detail page name the same string `prompt` with the same word.
    public const val AUTOMATION_EDITOR_CHANGE_TIMING: String = "修改计划时间"
    public const val AUTOMATION_EDITOR_CURRENT_RULE: String = "当前规则"
    // A switch's position has to be readable as text as well as as a role: the row
    // prints the state the way every other row in this app does.
    public const val AUTOMATION_EDITOR_TOGGLE_ON: String = "已开启"
    public const val AUTOMATION_EDITOR_TOGGLE_OFF: String = "已关闭"
    public const val AUTOMATION_EDITOR_RULE_AFTER: String = "延迟一次"
    public const val AUTOMATION_EDITOR_RULE_AT: String = "指定时间"
    public const val AUTOMATION_EDITOR_RULE_EVERY: String = "固定间隔"
    public const val AUTOMATION_EDITOR_RULE_DAILY: String = "每天"
    public const val AUTOMATION_EDITOR_RULE_WEEKLY: String = "每周"
    public const val AUTOMATION_EDITOR_RULE_CRON: String = "自定义时间表"
    // The 规则 row's own label is AUTOMATION_RULE above; the picker's is the
    // same word (`Picker("规则", …)`, `:263`).
    public const val AUTOMATION_EDITOR_DELAY_FIELD: String = "延迟秒数"
    public const val AUTOMATION_EDITOR_DELAY_EDIT_FIELD: String = "延迟到期秒数"
    public const val AUTOMATION_EDITOR_AT_HINT: String =
        "需要包含时区，例如 2026-10-26T09:00:00+08:00。"
    public const val AUTOMATION_EDITOR_AT_FIELD: String = "ISO-8601 日期时间"
    public const val AUTOMATION_EDITOR_EVERY_FIELD: String = "间隔秒数（至少 60）"
    public const val AUTOMATION_EDITOR_TIME_FIELD: String = "本地时间 HH:mm:ss"
    public const val AUTOMATION_EDITOR_TIME_ZONE_FIELD: String = "IANA 时区"
    public const val AUTOMATION_EDITOR_WEEKDAYS_FIELD: String = "星期（ISO 1–7，以逗号分隔）"
    public const val AUTOMATION_EDITOR_CRON_FIELD: String = "五段 Cron 表达式"
    // 保存 / 取消 (`:281`, `:283`). 取消 is UiStrings.CANCEL: the baseline's word,
    // already carried for the delete confirmation.
    public const val AUTOMATION_EDITOR_SAVE: String = "保存"
    // The rule validation sentences, verbatim (`timingValidationMessage()`, `:397`).
    public const val AUTOMATION_EDITOR_ERROR_AFTER: String = "请输入大于0的延迟秒数。"
    public const val AUTOMATION_EDITOR_ERROR_AT: String = "请输入带时区的有效 ISO-8601 日期时间。"
    public const val AUTOMATION_EDITOR_ERROR_EVERY: String = "固定间隔至少为60秒。"
    public const val AUTOMATION_EDITOR_ERROR_DAILY: String = "每天提醒需要有效的本地时间和 IANA 时区。"
    public const val AUTOMATION_EDITOR_ERROR_WEEKLY: String =
        "每周提醒需要有效时间/时区，并选择 1–7 的星期。"
    public const val AUTOMATION_EDITOR_ERROR_CRON: String = "Cron 需要五段表达式和有效 IANA 时区。"
    public const val AUTOMATION_EDITOR_ERROR_UNKNOWN_RULE: String = "请检查计划规则。"
    // Android's own disclosure, not the baseline's: §1 makes a save a handoff on
    // this host, and a form that silently keeps its values must say why.
    public const val AUTOMATION_EDITOR_HANDOFF_HINT: String =
        "保存会提交给宿主；本宿主未实现定时任务存储，表单会保留已填内容"

    // SessionArtifactPreviewPage (`SessionArtifactsPage.swift:296`–`:319`): the
    // preview 分享 verb (`:313`). iOS renders the file in a `QLPreviewController`
    // and shares its URL; Android has no system previewer, so the page shows the
    // baseline's own fallback sentence (`:304`–`:305`) plus the one platform fact
    // the iOS page does not need, and shares through the system chooser.
    public const val ARTIFACTS_PREVIEW_SHARE: String = "分享"
    public const val ARTIFACTS_PREVIEW_SHARE_CHOOSER: String = "分享产物"
    public const val ARTIFACTS_PREVIEW_PLATFORM_NOTE: String =
        "Android 没有系统预览器；分享给其他应用即可打开。"
    // What the chooser carries when the store has no content uri for the file:
    // the artifact's own name, size and id, so the receiving app knows what it is.
    public const val ARTIFACTS_PREVIEW_SHARE_TEXT: String = "%s（%s，%s）"

    // L24 lane: the chat family's three embedded subpages, which the iOS page keeps
    // in its own file (`ChatPage.swift:3504` NativeScheduleListSheet, `:3554`
    // NativeJobListSheet, `:4243` CommandExecutionResultPage). README §1 lists them
    // as 内嵌子页, so they are implemented with the parent page. Appended only.
    /** The two list sheets' trailing toolbar verb (`ChatPage.swift:3544`, `:3593`). */
    public const val CHAT_SUBPAGE_REFRESH: String = "刷新"

    /** The command-result page's trailing toolbar verb (`ChatPage.swift:4276`). */
    public const val CHAT_SUBPAGE_DONE: String = "完成"

    // 定时任务 sheet (`ChatPage.swift:3504`–`:3552`): the navigation title and the
    // `ContentUnavailableView` pair the baseline shows when it has no rows.
    public const val CHAT_SCHEDULES_TITLE: String = "定时任务"
    public const val CHAT_SCHEDULES_EMPTY_TITLE: String = "没有定时任务"
    public const val CHAT_SCHEDULES_EMPTY_DETAIL: String = "这个会话暂时没有定时任务。"

    // Android's own line, not the baseline's: the empty sentence above claims the
    // host *reported* no schedules. "Not reported" is a different fact, so a host
    // that made no read says this instead of claiming an empty session.
    public const val CHAT_SCHEDULES_UNREAD: String = "读取不到这个会话的定时任务。"

    // 后台任务 sheet (`ChatPage.swift:3554`–`:3601`).
    public const val CHAT_JOBS_TITLE: String = "后台任务"
    public const val CHAT_JOBS_EMPTY_TITLE: String = "没有后台任务"
    public const val CHAT_JOBS_EMPTY_DETAIL: String = "这个会话暂时没有后台任务。"
    public const val CHAT_JOBS_UNREAD: String = "读取不到这个会话的后台任务。"

    // 命令结果 (`ChatPage.swift:4243`–`:4299`): the status line, the empty-output
    // sentence and the Android-only unread line (this host owns no
    // `commands/execute`, so there is no execution to show by default).
    public const val CHAT_COMMAND_RESULT_TITLE: String = "命令结果"
    public const val CHAT_COMMAND_RESULT_SUCCESS: String = "命令已完成"
    public const val CHAT_COMMAND_RESULT_FAILED: String = "命令执行失败"
    public const val CHAT_COMMAND_RESULT_EMPTY: String = "这次没有更多输出。"
    public const val CHAT_COMMAND_RESULT_UNREAD: String = "读取不到这次命令的结果。"

    // -----------------------------------------------------------------------
    // Appended by the L29 lane: the single preview face. iOS PR #15 (`8dd17496`,
    // `PreviewSurface.swift`) replaced the files page's private preview sheet with
    // one full-screen surface; these are the sentences that surface owns.
    //
    // `FILES_PREVIEW_LOADING` (「正在读取…」) is reused as the first frame's word
    // and `FILES_PREVIEW_SHARE` (「分享」) / `RETRY` (「重试」) as the two verbs, so
    // the preview does not grow a second spelling of a word the app already has.
    //
    // The `PREVIEW_REASON_*` block has no iOS counterpart on purpose: Quick Look, a
    // library page and PDFKit cover all eleven kinds on iOS, so its unsupported card
    // never explains itself. Android has no renderer for six of them, and "temporarily
    // cannot preview" without a reason is the same lie as "the file is gone".
    // -----------------------------------------------------------------------

    /** `:275`: the paging footer while the next 512 KiB page is in flight. */
    public const val PREVIEW_LOADING_MORE: String = "正在加载更多…"

    /** `:283`: the paging footer's action while the file has more bytes. */
    public const val PREVIEW_LOAD_MORE: String = "加载更多"

    /** Android-only: how much of the file the paged body has read, and its size. */
    public const val PREVIEW_PROGRESS: String = "已读 %s / 共 %s"

    /** `:265`: the failure card's title. */
    public const val PREVIEW_UNAVAILABLE: String = "无法预览"

    /** `:158`: the bounded retry's answer after twelve waits (`:148`). */
    public const val PREVIEW_STILL_WRITING: String = "这个文件还在写入，或已不在工作区。等待同步后重试。"

    /** Android-only: the path names a directory, which no renderer can open. */
    public const val PREVIEW_NOT_A_FILE: String = "这个路径是文件夹，不是文件。"

    /** `:510`: the unsupported card's title. */
    public const val PREVIEW_UNSUPPORTED_TITLE: String = "暂时不能预览这个文件"

    /** `:512`: the unsupported card's way out. */
    public const val PREVIEW_UNSUPPORTED_HINT: String = "可以分享文件，或使用其他 App 打开。"

    /** `:537`: the unsupported card's share verb (the toolbar's is 「分享」). */
    public const val PREVIEW_SHARE_FILE: String = "分享文件"

    /** Android-only: `startActivity` found nothing that accepts the file. */
    public const val PREVIEW_SHARE_FAILED: String = "没有可以接收这个文件的 App。"

    /** Android-only reasons: what this host is missing, per kind. */
    public const val PREVIEW_REASON_OFFICE: String = "本机没有 Office 渲染器。"
    public const val PREVIEW_REASON_HTML: String = "HTML 预览需要第二个 WebView；本机只允许一个。"
    public const val PREVIEW_REASON_VIDEO: String = "视频播放器还没接上。"
    public const val PREVIEW_REASON_AUDIO: String = "音频播放器还没接上。"
    public const val PREVIEW_REASON_MODEL: String = "3D 预览需要 WebView。"
    public const val PREVIEW_REASON_WEB_MEDIA: String = "这个媒体格式需要 WebView。"

    /** Android-only: a page whose bytes stop being UTF-8 mid-file. */
    public const val PREVIEW_NOTICE_BINARY: String = "后面的内容不是 UTF-8 文本，已停止读取。"

    /** Android-only: `BitmapFactory` decodes a GIF's first frame and nothing more. */
    public const val PREVIEW_NOTICE_GIF: String = "动图只显示第一帧。"

    /** Android-only: `PdfRenderer` is bounded so a 900-page manual cannot OOM. */
    public const val PREVIEW_NOTICE_PDF_CAPPED: String = "只渲染了前 %s 页（共 %s 页）。"

    /** Android-only: the image body could not decode the file. */
    public const val PREVIEW_IMAGE_FAILED: String = "无法显示图片"
    public const val PREVIEW_IMAGE_FAILED_HINT: String = "图片格式不受支持，或文件仍在写入。"

    /** Android-only: the PDF body's two states. */
    public const val PREVIEW_PDF_RENDERING: String = "正在打开 PDF…"
    public const val PREVIEW_PDF_FAILED: String = "无法打开 PDF"
    public const val PREVIEW_PDF_FAILED_HINT: String = "文件可能已加密或仍在写入。"

    // -----------------------------------------------------------------------
    // Appended by the L32 lane: the video and audio bodies. PR #15 renders both
    // with one `AVPlayer` (`PreviewSurface.swift:305`) and `VideoPlayer` draws the
    // chrome; this host keeps the one-player shape (`PreviewPlayback.kt`) and
    // draws its own transport, so the three words that transport needs live here
    // instead of being spelled inline in the surface.
    //
    // `PREVIEW_MEDIA_TIME` is the clock both bodies print (`0:07 / 0:32`); the
    // `PREVIEW_PLAYBACK_FAILED_*` block is the decoder's error taxonomy in words a
    // person can act on (the page's 无法预览 card prints one of them as its reason).
    // -----------------------------------------------------------------------

    /** `:389`: the frame between a resolved file and a prepared player. */
    public const val PREVIEW_VIDEO_PREPARING: String = "准备播放器…"

    /** The transport's two verbs; `PREVIEW_PLAYBACK_FOCUS_PAUSED` explains a third state. */
    public const val PREVIEW_PLAY: String = "播放"
    public const val PREVIEW_PAUSE: String = "暂停"

    /** The audio card's duration line, and its honest answer when the codec has none. */
    public const val PREVIEW_MEDIA_DURATION: String = "时长 %s"
    public const val PREVIEW_MEDIA_DURATION_UNKNOWN: String = "时长未知"

    /** `0:07 / 0:32`; the second placeholder is absent when the duration is unknown. */
    public const val PREVIEW_MEDIA_TIME: String = "%s / %s"

    /** Audio focus was taken by something else, so the pause was not the user's. */
    public const val PREVIEW_PLAYBACK_FOCUS_PAUSED: String = "另一个 App 正在使用音频，播放已暂停。"

    /** `MediaPlayer`'s `MEDIA_ERROR_*` taxonomy, one sentence per actionable cause. */
    public const val PREVIEW_PLAYBACK_FAILED_IO: String = "读不到这个媒体文件。"
    public const val PREVIEW_PLAYBACK_FAILED_MALFORMED: String =
        "文件已损坏或不是完整的媒体文件。"
    public const val PREVIEW_PLAYBACK_FAILED_UNSUPPORTED: String = "本机没有这个媒体格式的解码器。"
    public const val PREVIEW_PLAYBACK_FAILED_TIMED_OUT: String = "播放器等待超时。"
    public const val PREVIEW_PLAYBACK_FAILED_CRASHED: String = "播放器出错了，请重试。"
    public const val PREVIEW_PLAYBACK_FAILED_UNKNOWN: String = "播放器无法打开这个文件。"

    // -----------------------------------------------------------------------
    // Appended by the L33 lane: the unsupported card's reasons, rewritten per
    // *file* instead of per kind.
    //
    // The L29 sentences these supersede (`PREVIEW_REASON_HTML`,
    // `PREVIEW_REASON_MODEL`, `PREVIEW_REASON_WEB_MEDIA`) told the reader about a
    // "WebView" and answered one sentence for three different media formats. A
    // person can act on neither. This object is append-only for the lane, so those
    // three stay declared (and unreachable) instead of being edited away; the
    // mapping that replaces them is `PreviewUnsupported.kt`, whose test fails the
    // build if implementation vocabulary comes back.
    // -----------------------------------------------------------------------

    /** L33 / `HTML`: the file's own scripts, in a surface this host does not have. */
    public const val PREVIEW_REASON_HTML_PAGE: String =
        "网页预览会执行这个文件里的脚本；App 里还没有能安全运行网页的预览页。"

    /** L33 / `MODEL`: three.js needs the same surface. */
    public const val PREVIEW_REASON_MODEL_VIEWER: String =
        "3D 模型要用 three.js 在网页里渲染；App 里还没有能安全运行网页的预览页。"

    /** L33 / `WEB_MEDIA` × `.gif`: an animated decoder, not a page and not a player. */
    public const val PREVIEW_REASON_WEB_MEDIA_GIF: String =
        "动图预览还没接上；这里的图片解码只取第一帧，所以不假装它在动。"

    /** L33 / `WEB_MEDIA` × `.webm`: a player route, not a page. */
    public const val PREVIEW_REASON_WEB_MEDIA_VIDEO: String =
        "这个视频格式还没有接到播放器上。"

    /** L33 / `WEB_MEDIA` × `.ogv`: `Theora` has no decoder in the platform. */
    public const val PREVIEW_REASON_WEB_MEDIA_OGV: String =
        "本机没有 OGV（Theora）解码器。"

    // -----------------------------------------------------------------------
    // Appended by the L74 lane: two page titles the settings family was
    // rendering with another page's words. Appended only — nothing above is
    // rewritten.
    // -----------------------------------------------------------------------

    /**
     * 通用设置 — the 通用 tab's own navigation title.
     *
     * `SettingsPage.swift:14` (`NativeSettingsTab.general.title`) and the page's
     * `.navigationTitle` at `:168`. The shell's bar draws the active tab's title,
     * so this is the one tab whose bar title is not the sheet's own 设置.
     */
    public const val SETTINGS_GENERAL_TITLE: String = "通用设置"

    /**
     * The MCP list page's title. `MCPSettingsPage.swift:101`
     * (`.navigationTitle("MCP 网络与密钥")`); `MCP_TITLE` above ("MCP 服务器") is
     * the drawer row's word and is not this page's heading.
     */
    public const val MCP_NETWORK_TITLE: String = "MCP 网络与密钥"

    /**
     * The 关于 card's one footnote, verbatim from `NativeShell.swift:902`
     * (`Text("会话记录和文件都保存在这台手机上。")`).
     */
    public const val ABOUT_LOCAL_NOTE: String = "会话记录和文件都保存在这台手机上。"

    // ---------------------------------------------------------------------
    // PR22 visible copy (iOS `edd68746`, 430x932pt HomeSpec language).
    //
    // Appended by the PR14/PR22 alignment lane. Everything below is product
    // copy the PR22 iOS sources actually render, character for character; `_EN`
    // is the same label's English fallback where the baseline is bilingual
    // (`NativeText(zh, en)`). Existing constants above are reused when the
    // literal already exists (a few semantic aliases point at the existing
    // constant instead of re-typing it), so this block never spells one visible
    // string twice. Dynamic lines are `%` templates and never contain a Swift
    // interpolation.
    // ---------------------------------------------------------------------

    // Home header and menu (PR22 `ChatPage.swift` chatHeader / chatHeaderMenu)
    public const val HOME_RENAME_HINT: String = "点按重命名会话"
    public const val HOME_DEVICE: String = "连接设备"
    public const val HOME_DEVICE_ONLINE: String = "连接设备，有在线设备"
    public const val HOME_MENU_SUBAGENTS: String = "子智能体（%d）"
    public const val HOME_MENU_JOBS: String = "后台任务（%d）"
    public const val HOME_MENU_SCHEDULES: String = "定时任务（%d）"
    public const val HOME_MENU_PRESET: String = "Agent 预设：%s"
    public const val HOME_EXPORT_SUBJECT: String = "对话记录"

    // Home drawer (PR22 `HomeDrawer.swift`)
    public const val DRAWER_DEFAULT_FOLDER: String = "手机工作区"
    public const val DRAWER_DEFAULT_FOLDER_EN: String = "Phone Workspace"
    public const val DRAWER_DEFAULT_FOLDER_INDEXED: String = "手机工作区 %d"
    public const val DRAWER_DEFAULT_FOLDER_INDEXED_EN: String = "Phone Workspace %d"
    public const val DRAWER_NEW_SESSION_EN: String = "New Session"
    public const val DRAWER_NEW_BLOCKED_ENGINE_EN: String = "Engine not started"
    public const val DRAWER_NEW_BLOCKED_TURN_EN: String = "Available after this turn"
    public const val DRAWER_CREATE_DETAIL: String = "会在工作区里新建同名文件夹，之后的会话和文件都可以放进去。"
    public const val DRAWER_EDIT_NAME: String = "编辑名称"
    public const val DRAWER_RENAME_FOLDER: String = "重命名文件夹"
    public const val DRAWER_DELETE_FOLDER: String = "删除文件夹"
    public const val DRAWER_DELETE_FOLDER_CONFIRM: String = "删除「%s」？"
    public const val DRAWER_DELETE_FOLDER_DETAIL: String = "里面的会话会留着，只是不再放在这个文件夹里。"
    public const val DRAWER_EMPTY_FOLDERS: String = "还没有文件夹。点右上角的 + 新建一个，会话和文件都能放进去。"
    public const val DRAWER_SESSION_ARCHIVE: String = "归档"
    public const val DRAWER_ARCHIVED_TOAST: String = "已归档，可在 设置 › 已归档会话 里找回"
    public const val DRAWER_COLLAPSED: String = "已收起"
    public const val DRAWER_ENGINE_STARTING: String = "引擎启动中"
    public const val DRAWER_ENGINE_STOPPED: String = "引擎未启动"
    public const val DRAWER_ENGINE_NEEDS_MODEL: String = "待配置模型"
    public const val DRAWER_ENGINE_READY: String = "引擎就绪"
    public const val DRAWER_NEW_BLOCKED_TURN: String = "本轮结束后可用"
    public const val DRAWER_SETTINGS_A11Y: String = "设置，%s"

    // Settings index and its sub-pages (PR22 `SettingsPage.swift`)
    public const val SETTINGS_SECTION_MODELS_AGENTS: String = "模型与智能体"
    public const val SETTINGS_SECTION_MODELS_AGENTS_EN: String = "Models and agents"
    public const val SETTINGS_SECTION_PERMISSIONS_PRIVACY: String = "权限与隐私"
    public const val SETTINGS_SECTION_PERMISSIONS_PRIVACY_EN: String = "Permissions and privacy"
    public const val SETTINGS_SECTION_CONVERSATION: String = "对话"
    public const val SETTINGS_SECTION_CONVERSATION_EN: String = "Conversation"
    public const val SETTINGS_SECTION_SESSIONS_FILES: String = "会话与文件"
    public const val SETTINGS_SECTION_SESSIONS_FILES_EN: String = "Sessions and files"
    public const val SETTINGS_ROW_LANGUAGE: String = "语言"
    public const val SETTINGS_ROW_LANGUAGE_EN: String = "Language"
    public const val SETTINGS_ROW_WORK_DETAILS: String = "工作过程"
    public const val SETTINGS_ROW_WORK_DETAILS_EN: String = "Work details"
    public const val SETTINGS_ROW_ARCHIVED_SESSIONS: String = "已归档会话"
    public const val SETTINGS_ROW_ARCHIVED_SESSIONS_EN: String = "Archived sessions"
    public const val SETTINGS_ROW_PHONE_PERMISSION_COUNT: String = "%d / %d 已允许"
    public const val SETTINGS_ROW_PHONE_PERMISSION_COUNT_EN: String = "%d / %d allowed"
    public const val SETTINGS_LANGUAGE_ZH: String = "中文"
    public const val SETTINGS_LANGUAGE_EN: String = "English"
    public const val SETTINGS_ENGINE_RESET_FOOTER: String = "上次启动失败后引擎不会自动重试。重新启动会确认这次失败并重新启动，会话数据不受影响。"
    public const val SETTINGS_ENGINE_RESET_FOOTER_EN: String =
        "The engine does not retry after a failure. Restarting acknowledges it and boots again; session data is kept."
    public const val WORK_DETAILS_SHOW: String = "显示方式"
    public const val WORK_DETAILS_SHOW_EN: String = "Show"
    public const val WORK_DETAILS_COMPACT: String = "简洁"
    public const val WORK_DETAILS_COMPACT_EN: String = "Compact"
    public const val WORK_DETAILS_VERBOSE: String = "完全展开"
    public const val WORK_DETAILS_VERBOSE_EN: String = "Verbose"
    public const val WORK_DETAILS_COLLAPSE: String = "收起时机"
    public const val WORK_DETAILS_COLLAPSE_EN: String = "Collapse"
    public const val WORK_DETAILS_COLLAPSE_DONE: String = "回答结束后"
    public const val WORK_DETAILS_COLLAPSE_DONE_EN: String = "After completion"
    public const val WORK_DETAILS_COLLAPSE_NEXT: String = "下次有新消息时"
    public const val WORK_DETAILS_COLLAPSE_NEXT_EN: String = "With the next input"
    public const val WORK_DETAILS_CODE_VIEW: String = "显示代码工作视图"
    public const val WORK_DETAILS_CODE_VIEW_EN: String = "Show code work"
    public const val WORK_DETAILS_STEPS: String = "工作步骤"
    public const val WORK_DETAILS_STEPS_EN: String = "Work steps"
    public const val WORK_DETAILS_BUSY: String = "任务进行中发送"
    public const val WORK_DETAILS_BUSY_EN: String = "While busy"
    public const val WORK_DETAILS_QUEUE: String = "排队发送"
    public const val WORK_DETAILS_QUEUE_EN: String = "Queue"
    public const val WORK_DETAILS_STEER: String = "引导当前任务"
    public const val WORK_DETAILS_STEER_EN: String = "Steer"
    public const val WORK_DETAILS_PERF: String = "性能与用量"
    public const val WORK_DETAILS_PERF_EN: String = "Performance and usage"
    public const val WORK_DETAILS_SENDING: String = "发送与用量"
    public const val WORK_DETAILS_SENDING_EN: String = "Sending and usage"
    public const val WORK_DETAILS_QUEUE_FOOTER: String = "排队发送会等当前任务结束再处理；引导会把新消息交给正在进行的任务。"
    public const val WORK_DETAILS_QUEUE_FOOTER_EN: String =
        "Queue waits for the current task; steer hands the message to the running task."
    public const val FONT_SIZE_TERMINAL: String = "终端"
    public const val FONT_SIZE_TERMINAL_EN: String = "Terminal"
    public const val FONT_SIZE_FAMILY_PLACEHOLDER: String = "字体（留空使用系统默认）"
    public const val FONT_SIZE_FAMILY_PLACEHOLDER_EN: String = "Font family (system default)"
    public const val FONT_SIZE_MISSING_FORMAT: String = "未安装字体 %s，将使用系统回退字体"
    public const val FONT_SIZE_MISSING_FORMAT_EN: String = "Font %s is unavailable; system fallback will be used"
    public const val SESSIONS_ARCHIVED_EMPTY_EN: String = "No archived sessions"
    public const val ARCHIVED_EMPTY_HINT: String = "在侧边栏长按会话选「归档」，会话会收到这里，随时可以恢复。"
    public const val ARCHIVED_EMPTY_HINT_EN: String =
        "Long-press a session in the drawer and choose Archive; restore it here any time."
    public const val ARCHIVED_RESTORE_FOOTER: String = "恢复后，会话回到原来的文件夹。"
    public const val ARCHIVED_RESTORE_FOOTER_EN: String = "Restored sessions return to their folder."
    public const val PERMISSION_DEFAULTS_SCOPE: String = PERMISSION_DEFAULTS_NOTE
    public const val PERMISSION_DEFAULTS_SCOPE_EN: String =
        "Only new sessions use this default; the current session is unchanged."
    // Legacy constant names retained for source compatibility. The values name
    // the libraries this Android artifact actually distributes, not iOS's
    // SwiftTerm/swift-nio (which the app does not ship).
    public const val LICENSES_SWIFTTERM: String = "AndroidX / Jetpack Compose"
    public const val LICENSES_SWIFT_NIO: String = "Kotlin · kotlinx.coroutines · Ktor"
    public const val LICENSES_MIT: String = "MIT"
    public const val LICENSES_APACHE: String = "Apache 2.0"
    public const val SETTINGS_EN: String = "Settings"
    public const val SETTINGS_DONE_EN: String = "Done"
    public const val MODEL_PROVIDER_TITLE_EN: String = "Model providers"
    public const val PERMISSION_DEFAULTS_TITLE_EN: String = "Default permission"
    public const val PHONE_PERMISSIONS_TITLE_EN: String = "Phone permissions"
    public const val SETTINGS_ROW_NETWORK_EN: String = "Network access"
    public const val SETTINGS_ROW_APPEARANCE_EN: String = "Appearance"
    public const val SETTINGS_ROW_FONT_SIZE_EN: String = "Text size"
    public const val SETTINGS_ROW_SHORTCUTS_EN: String = "Shortcuts"
    public const val SETTINGS_ROW_ENGINE_EN: String = "Engine"
    public const val SETTINGS_ROW_RESTART_EN: String = "Restart engine"
    public const val SETTINGS_ROW_RUNTIME_EN: String = "Runtime details"

    // Provider list and editor (PR22 `ModelProviderSettingsPage.swift`)
    public const val PROVIDER_SAVED_FORMAT: String = "已保存“%s”。%s"
    public const val PROVIDER_SAVED_FORMAT_EN: String = "Saved “%s”. %s"
    public const val PROVIDER_SELECTED_FORMAT: String = "已选择“%s”。%s"
    public const val PROVIDER_SELECTED_FORMAT_EN: String = "Selected “%s”. %s"
    public const val PROVIDER_DELETED_FORMAT: String = "已删除“%s”。%s"
    public const val PROVIDER_DELETED_FORMAT_EN: String = "Deleted “%s”. %s"
    public const val PROVIDER_EMPTY_TITLE: String = "尚未配置模型服务"
    public const val PROVIDER_EMPTY_TITLE_EN: String = "No Model Providers"
    public const val PROVIDER_EMPTY_BODY: String = "添加一个模型服务并填入密钥;密钥只存在这台手机上。"
    public const val PROVIDER_EMPTY_BODY_EN: String =
        "Add a model provider and its key. The key is stored only on this phone."
    public const val PROVIDER_PRIVACY_FOOTER: String = "这个选择从下一次启动本地引擎起生效。密钥不会写进配置、日志或网页。"
    public const val PROVIDER_PRIVACY_FOOTER_EN: String =
        "This selection takes effect the next time the local engine starts. Keys are never written to configuration, logs or web pages."
    public const val PROVIDER_KEY_SAVED: String = "密钥已保存"
    public const val PROVIDER_KEY_SAVED_EN: String = "Key saved"
    public const val PROVIDER_KEY_MISSING: String = "未保存密钥"
    public const val PROVIDER_KEY_MISSING_EN: String = "No key saved"
    public const val PROVIDER_KEY_UNREADABLE: String = "读不到密钥"
    public const val PROVIDER_KEY_UNREADABLE_EN: String = "Key unavailable"
    public const val PROVIDER_RESTART_RUNNING: String = "保存后需要停止并重新启动主机，新的服务和模型才会用于后续请求。"
    public const val PROVIDER_RESTART_RUNNING_EN: String =
        "After saving, stop and restart the host so subsequent requests use the new provider and model."
    public const val PROVIDER_DELETE_BLOCKED: String = "无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试。"
    public const val PROVIDER_DELETE_BLOCKED_EN: String =
        "The key on this device could not be read, so the provider and its key cannot be deleted. Unlock the device, reload this page, and try again."
    public const val PROVIDER_NAME_PLACEHOLDER: String = "例如 DeepSeek"
    public const val PROVIDER_KEY_PLACEHOLDER_SAVED: String = "已保存，输入以替换"
    public const val PROVIDER_KEY_PLACEHOLDER: String = "粘贴或输入 API 密钥"
    public const val PROVIDER_API_URL: String = "API 地址"
    public const val PROVIDER_API_URL_EN: String = "API URL"
    public const val PROVIDER_URL_PLACEHOLDER: String = "https://api.deepseek.com/v1"
    public const val PROVIDER_SECTION_CONNECTION: String = "连接信息"
    public const val PROVIDER_SECTION_CONNECTION_EN: String = "Connection"
    public const val PROVIDER_CONNECTION_FOOTER: String =
        "填写这三项，然后获取模型。密钥保存在本机应用私有存储中；设备支持时使用 Android Keystore 加密。"
    public const val PROVIDER_CONNECTION_FOOTER_EN: String =
        "Enter these three fields, then fetch models. Keys stay in this app’s private storage; Android Keystore encryption is used when available."
    public const val PROVIDER_FETCHING: String = "正在获取模型…"
    public const val PROVIDER_FETCH: String = "获取模型"
    public const val PROVIDER_MODEL_FOOTER: String = "获取后选择默认模型。接口不支持模型列表时，可在高级设置中手动添加。"
    public const val PROVIDER_ADVANCED: String = "高级设置"
    public const val PROVIDER_ADVANCED_EN: String = "Advanced settings"
    public const val PROVIDER_ADVANCED_FOOTER: String = "推理强度、上下文和输出长度沿用默认值。"
    public const val PROVIDER_SAVE_EN: String = "Save"
    public const val PROVIDER_KEY_READ_FAILED_FORMAT: String = "无法读取此设备的密钥：%s"
    public const val PROVIDER_KEY_READ_FAILED_FORMAT_EN: String = "Could not read the key on this device: %s"
    public const val PROVIDER_ADVANCED_SECTION: String = "服务选项"
    public const val PROVIDER_IDENTIFIER_PLACEHOLDER: String = "留空自动生成"
    public const val PROVIDER_IDENTIFIER_PLACEHOLDER_EN: String = "Generated if empty"
    public const val PROVIDER_DEFAULT_OPTION_EN: String = "Default"
    public const val PROVIDER_OPTIONAL: String = "可选"
    public const val PROVIDER_OPTIONAL_EN: String = "Optional"
    public const val PROVIDER_TOKENS: String = "Token 数"
    public const val PROVIDER_TOKENS_EN: String = "Tokens"
    public const val PROVIDER_MAX_OUTPUT: String = "最大输出"
    public const val PROVIDER_MAX_OUTPUT_EN: String = "Max output"
    public const val PROVIDER_EFFORT_FIELD: String = "推理档位"
    public const val PROVIDER_EFFORT_FIELD_EN: String = "Effort"
    public const val PROVIDER_DELETE_MODEL_PR22: String = "删除这个模型"
    public const val PROVIDER_DELETE_MODEL_PR22_EN: String = "Delete This Model"
    public const val PROVIDER_SECTION_KEY_CONNECTION: String = "密钥与连接"
    public const val PROVIDER_TESTING: String = "正在测试…"
    public const val PROVIDER_TEST_CONNECTION: String = "测试连接"
    public const val PROVIDER_CONNECTED: String = "连接正常"
    public const val PROVIDER_CONNECTED_EN: String = "Connected"
    public const val PROVIDER_ERR_URL_HTTPS: String = "请输入有效的 HTTPS API 地址。"
    public const val PROVIDER_ERR_KEY_READ: String = "无法读取已保存的密钥，请解锁手机后重试。"
    public const val PROVIDER_ERR_KEY_REQUIRED: String = "请先填写 API 密钥。"
    public const val PROVIDER_ERR_RESPONSE: String = "接口未返回有效响应。"
    public const val PROVIDER_ERR_AUTH: String = "密钥未被接受，请检查密钥与 API 地址是否属于同一服务。"
    public const val PROVIDER_ERR_MODELS_UNSUPPORTED: String = "此地址不支持获取模型，请检查 API 地址或在高级设置中手动添加。"
    public const val PROVIDER_ERR_RATE: String = "请求过于频繁，请稍后再试。"
    public const val PROVIDER_ERR_HTTP: String = "获取模型失败（HTTP %d），请稍后重试。"
    public const val PROVIDER_ERR_LIST_TOO_LARGE: String = "模型列表过大，请在高级设置中手动添加。"
    public const val PROVIDER_ERR_LIST_EMPTY: String = "服务未返回可用的模型列表。"
    public const val PROVIDER_ERR_NETWORK: String = "暂时无法获取模型，请检查网络与 API 地址，或在高级设置中手动添加。"
    public const val PROVIDER_FETCHED_FORMAT: String = "已获取 %d 个模型，选择后点保存。"
    public const val PROVIDER_VALIDATION_NO_MODEL: String = "至少添加一个模型"
    public const val PROVIDER_VALIDATION_NO_MODEL_EN: String = "Add at least one model"
    public const val PROVIDER_VALIDATION_ID_EMPTY: String = "模型 ID 不能为空"
    public const val PROVIDER_VALIDATION_ID_EMPTY_EN: String = "Model IDs cannot be empty"
    public const val PROVIDER_VALIDATION_ID_DUPLICATE: String = "模型 ID 不能重复"
    public const val PROVIDER_VALIDATION_ID_DUPLICATE_EN: String = "Model IDs must be unique"
    public const val PROVIDER_VALIDATION_INPUT: String = "每个模型至少保留文本或图片一种输入类型"
    public const val PROVIDER_VALIDATION_INPUT_EN: String = "Each model must support text or image input"
    public const val PROVIDER_VALIDATION_POSITIVE: String = "上下文窗口和最大输出必须是正整数"
    public const val PROVIDER_VALIDATION_POSITIVE_EN: String =
        "Context window and maximum output must be positive integers"
    public const val PROVIDER_TEST_NO_KEY: String = "还没有保存密钥。"
    public const val PROVIDER_TEST_NO_KEY_EN: String = "No API key has been saved."
    public const val PROVIDER_TEST_KEY_READ_FORMAT: String = "读不到已保存的密钥：%s"
    public const val PROVIDER_TEST_KEY_READ_FORMAT_EN: String = "Could not read the saved key: %s"
    public const val PROVIDER_TEST_URL_EMPTY: String = "接口地址是空的。"
    public const val PROVIDER_TEST_URL_EMPTY_EN: String = "The service URL is empty."
    public const val PROVIDER_TEST_OK: String = "连接正常（HTTP %d，%s，%s）。密钥可用。"
    public const val PROVIDER_TEST_OK_EN: String = "Connected (HTTP %d, %s, %s). The key is valid."
    public const val PROVIDER_TEST_REJECTED: String = "密钥被拒绝（HTTP %d，%s）。确认密钥与“%s”属于同一个平台。"
    public const val PROVIDER_TEST_REJECTED_EN: String =
        "The key was rejected (HTTP %d, %s). Make sure the key and “%s” belong to the same platform."
    public const val PROVIDER_TEST_RATE: String = "请求太频繁（HTTP %d），密钥本身是有效的。"
    public const val PROVIDER_TEST_RATE_EN: String = "Too many requests (HTTP %d). The key itself is valid."
    public const val PROVIDER_TEST_NOT_FOUND: String = "%s 路径不存在（HTTP 404）"
    public const val PROVIDER_TEST_NOT_FOUND_EN: String = "%s path not found (HTTP 404)"
    public const val PROVIDER_TEST_HTTP: String = "HTTP %d：%s"
    public const val PROVIDER_TEST_HTTP_EN: String = "HTTP %d: %s"
    public const val PROVIDER_TEST_UNREACHABLE: String = "连不上：%s"
    public const val PROVIDER_TEST_UNREACHABLE_EN: String = "Connection failed: %s"
    public const val PROVIDER_TEST_FAILED: String = "测试失败：%s。检查接口地址与模型名“%s”。"
    public const val PROVIDER_TEST_FAILED_EN: String =
        "Test failed: %s. Check the service URL and model name “%s”."
    public const val PROVIDER_TEST_NO_PROTOCOL: String = "没有可用协议"
    public const val PROVIDER_TEST_NO_PROTOCOL_EN: String = "No protocol available"
    public const val PROVIDER_TEST_BAD_URL: String = "接口地址填得不对"
    public const val PROVIDER_TEST_BAD_URL_EN: String = "Invalid service URL"
    public const val PROVIDER_PROTOCOL_OPENAI_LABEL: String = "OpenAI 兼容"
    public const val PROVIDER_PROTOCOL_OPENAI_LABEL_EN: String = "OpenAI-compatible"
    public const val PROVIDER_PROTOCOL_ANTHROPIC_LABEL: String = "Anthropic Messages"
    public const val PROVIDER_EFFORT_OFF_EN: String = "Off"
    public const val PROVIDER_EFFORT_LOW_EN: String = "Low"
    public const val PROVIDER_EFFORT_MEDIUM_EN: String = "Medium"
    public const val PROVIDER_EFFORT_HIGH_EN: String = "High"
    public const val PROVIDER_EFFORT_MAX_EN: String = "Max"
    public const val PROVIDER_EFFORT_MODEL_DEFAULT: String = "按模型默认"
    public const val PROVIDER_EFFORT_MODEL_DEFAULT_EN: String = "Model default"
    public const val PROVIDER_SERVICES_EN: String = "Providers"
    public const val PROVIDER_NAME_LABEL_EN: String = "Name"
    public const val PROVIDER_KEY_LABEL_EN: String = "API key"
    public const val PROVIDER_IDENTIFIER_LABEL_EN: String = "Identifier"
    public const val PROVIDER_DEFAULT_MODEL_EN: String = "Default model"
    public const val PROVIDER_REASONING_EFFORT_EN: String = "Reasoning effort"
    public const val PROVIDER_MODEL_ID_EN: String = "Model ID"
    public const val PROVIDER_TEXT_INPUT_EN: String = "Text input"
    public const val PROVIDER_IMAGE_INPUT_EN: String = "Image input"
    public const val PROVIDER_ADD_MODEL_EN: String = "Add Model"
    public const val PROVIDER_DELETE_SAVED_KEY_EN: String = "Delete saved key"

    // Composer, queue and message actions (PR22 `ChatPage.swift`)
    public const val CHAT_TOOL_FAILED_TITLE: String = "工具执行失败"
    public const val CHAT_QUEUE_EDIT_TITLE: String = "编辑排队消息"
    public const val CHAT_QUEUE_EDIT_CONTENT: String = "消息内容"
    public const val CHAT_QUEUE_EDIT_NOT_SAVED: String = "这条排队消息还没有落盘，暂时不能编辑"
    public const val CHAT_QUEUE_EDIT_NOT_TEXT: String = "包含非文本内容，暂不支持编辑"
    public const val CHAT_QUEUE_DELETE: String = "删除排队消息"
    public const val CHAT_QUEUE_STEER_SEND: String = "插话发送"
    public const val CHAT_QUEUE_STEER_UNAVAILABLE: String = "仅运行中可插话发送"
    public const val CHAT_QUEUE_LOCAL_ACTION_UNAVAILABLE: String = "这条排队消息还没有落盘，暂时不能操作"
    public const val CHAT_QUEUE_ACTION_BUSY: String = "正在处理队列操作…"
    public const val CHAT_QUEUE_ACTION_PENDING: String = "等待队列操作确认"
    public const val CHAT_QUEUE_ACTION_STALE: String = "操作状态已过期，等待队列刷新"
    public const val CHAT_QUEUE_ACTION_FAILED: String = "队列操作失败"
    public const val CHAT_QUEUE_EDIT_ITEM_GONE: String = "这条排队消息已不在队列里，编辑已关闭"
    public const val CHAT_QUEUE_HEADER_COUNT: String = "%d 条排队消息"
    public const val CHAT_QUEUE_SENDING: String = "发送中…"
    public const val CHAT_STEER_IMAGE_NOTICE_ALT: String = "补充说明不支持附带图片；请先移除图片，或改用排队发送。"
    public const val CHAT_COMMAND_NOT_RUN: String = "没执行成功，再试一次。"
    public const val CHAT_PREVIEW_UNSAFE_PATH: String = "这个路径不能预览。"
    public const val CHAT_COMMAND_WORD: String = "指令"
    public const val CHAT_IMPORT_NO_ENGINE: String = "本地引擎还没启动，启动之后才能把文件放进工作区。"
    public const val CHAT_IMPORT_CAP: String = "一次最多导入 128 MiB。"
    public const val CHAT_COMMAND_SHARE: String = "分享命令结果"
    public const val CHAT_ENGINE_STOP_TITLE: String = "停止本地引擎?"
    public const val CHAT_ENGINE_STOP_DETAIL: String = "正在跑的任务会停下来。会话和文件都还在。"
    public const val CHAT_ENGINE_STOP_FOOTER: String = "停止后,正在跑的任务会停下来,不会再接着做。"
    public const val CHAT_EVENT_USER: String = "用户消息"
    public const val CHAT_EVENT_ASSISTANT: String = "助手消息"
    public const val CHAT_EVENT_SYSTEM: String = "系统提示"
    public const val CHAT_EVENT_STEER: String = "补充说明"
    public const val CHAT_EVENT_DEVELOPER: String = "开发者消息"
    public const val CHAT_EVENT_TOOL_RESULT: String = "工具结果"
    public const val CHAT_EVENT_MODEL_REQUEST: String = "模型请求"
    public const val CHAT_EVENT_COMMAND: String = "DSH 命令"
    public const val CHAT_EVENT_BOUNDARY: String = "会话边界"
    public const val CHAT_EVENT_SESSION: String = "会话事件"
    public const val CHAT_EVENT_FORMAT_FAILED: String = "无法格式化此事件的原始数据。"
    public const val CHAT_EVENT_READ_FAILED: String = "无法读取此事件的原始数据。"
    public const val CHAT_EVENT_COPY: String = "复制事件数据"
    public const val CHAT_ADD_FILE: String = "添加文件"
    public const val COMPOSER_QUEUE_LABEL: String = "排队"

    // Question dock (PR22 `NativeQuestionComposer.swift`)
    public const val QUESTION_DOCK_TITLE: String = "问题"
    public const val QUESTION_INCOMPLETE: String = "请先完成这道问题。"
    public const val QUESTION_UNANSWERED: String = "请选择一个选项或填写自定义答案。"
    public const val QUESTION_UNAVAILABLE: String = "当前无法提交，请稍候再试。"
    public const val QUESTION_TAKE_TIME: String = "慢慢回答"
    public const val QUESTION_HELD: String = "会一直等你回答"
    public const val QUESTION_CONTINUED: String = "已继续工作，仍可回答"
    public const val QUESTION_ANSWERED: String = "已回答"
    public const val QUESTION_SKIPPED_REVIEW: String = "这道问题当时被跳过。"
    public const val QUESTION_PREV: String = "上一题"
    public const val QUESTION_NEXT: String = "下一题"
    public const val QUESTION_MINIMIZE: String = "收起问题卡片"
    public const val QUESTION_MAXIMIZE: String = "展开问题卡片"
    public const val QUESTION_CANCEL_GROUP: String = "放弃整组问题"
    public const val QUESTION_CLOSE: String = "收起问题面板，可从工具调用重新打开"
    public const val QUESTION_RECOMMENDED: String = "推荐"
    public const val QUESTION_CUSTOM_PLACEHOLDER: String = "输入你的答案"
    public const val QUESTION_SKIP: String = "跳过"
    public const val QUESTION_SUBMITTING: String = "正在提交…"
    public const val QUESTION_PAGE_FORMAT: String = "第 %d 题，共 %d 题"
    public const val QUESTION_ERROR_FORMAT: String = "错误：%s"
    public const val QUESTION_SELECTED: String = "已选中"
    public const val QUESTION_UNSELECTED: String = "未选中"
    public const val QUESTION_MULTIPLE: String = "可多选"

    // Todo / plan docks (PR22 `NativeTodoDock.swift`, `NativePlan*.swift`)
    public const val TODO_DOCK_TITLE: String = "任务"
    public const val TODO_EXPAND: String = "展开任务清单"
    public const val TODO_COLLAPSE: String = "折叠任务清单"
    public const val TODO_DONE_COUNT: String = "%d 已完成"
    public const val TODO_ACTIVE_COUNT: String = "%d 进行中"
    public const val TODO_PENDING_COUNT: String = "%d 待处理"
    public const val TODO_STATUS_PENDING: String = "待处理"
    public const val PLAN_CHIP_A11Y: String = "计划模式已开启，按下关闭"
    public const val PLAN_CHIP_HINT: String = "计划模式已开启 — 点击关闭（/plan off）"
    public const val PLAN_CHIP_EXIT_FAILED: String = "退出计划模式失败"
    public const val PLAN_REVIEW_HEADER: String = "计划待审"
    public const val PLAN_REVIEW_CHANGES: String = "要求修改"
    public const val PLAN_REVIEW_APPROVE: String = "同意执行"
    public const val PLAN_REVIEW_OPEN: String = "查看全文"
    public const val PLAN_REVIEW_OPEN_A11Y: String = "在侧边栏打开计划"
    public const val PLAN_CARD_SUBTITLE: String = "计划 · Markdown"
    public const val PLAN_CARD_OPEN: String = "打开"
    public const val PLAN_CARD_OPEN_A11Y: String = "打开计划：%s"

    // Schedules (PR22 `NativeAutomationPage.swift`)
    public const val AUTOMATION_REFRESH_A11Y: String = "刷新自动化任务"
    public const val AUTOMATION_HISTORY_OPEN_A11Y: String = "查看 DSH 已保存的投递记录"

    // Preview / files / share (PR22 `PreviewSurface.swift`, `FilesPage.swift`)
    public const val PREVIEW_NETWORK_PERMISSION: String = "网页网络权限"
    public const val PREVIEW_NETWORK_ALLOW: String = "允许本次加载外部图片/字体/媒体"
    public const val PREVIEW_RELOAD: String = "重新加载页面"
    public const val PREVIEW_LOCAL_NOTICE: String = "页面在本地 pdsh-page:// 源下运行；JavaScript 已启用，外部网络默认关闭。"
    public const val PREVIEW_OUTSIDE_WORKSPACE: String = "这个页面不在工作区里"
    public const val PREVIEW_OUTSIDE_WORKSPACE_HINT: String = "页面预览需要它所属的工作区；散落文件请用文本或分享打开。"
    public const val PREVIEW_MODEL_OUTSIDE_WORKSPACE: String = "这个模型不在工作区里"
    public const val PREVIEW_MODEL_OUTSIDE_WORKSPACE_HINT: String = "3D 预览需要文件所属的会话工作区。"
    public const val PREVIEW_MEDIA_OUTSIDE_WORKSPACE: String = "这个媒体不在工作区里"
    public const val PREVIEW_MEDIA_OUTSIDE_WORKSPACE_HINT: String = "动图/视频预览需要文件所属的会话工作区。"

    // Runtime, about and honest unread states (PR22 `ChatPage.swift`, `SettingsPage.swift`)
    public const val RUNTIME_MODEL_REQUESTS_FORMAT: String = "模型调用 %d"
    public const val ABOUT_LICENSES_EN: String = "Open-source licenses"
    public const val MODEL_LIST_UNAVAILABLE: String = "暂时读不到模型列表。"
    public const val MODEL_LIST_UNAVAILABLE_EN: String = "The model list is temporarily unavailable."
    public const val SUBTASK_MODELS_EMPTY: String = "没有可给子任务用的模型。"
    public const val SUBTASK_MODELS_EMPTY_EN: String = "No models are available for subtasks."
    public const val ABOUT_APP_TITLE: String = "关于 Phone DSH"
    public const val ABOUT_APP_TITLE_EN: String = "About Phone DSH"

    // Shared labels (one literal, used by several PR22 surfaces)
    public const val PLUGINS_AND_TOOLS: String = "插件与工具"
    public const val PLUGINS_AND_TOOLS_EN: String = "Plugins and tools"
    public const val FOLDERS_LABEL: String = "文件夹"
    public const val FOLDERS_LABEL_EN: String = "Folders"

    public const val FONT_SIZE_CONVERSATION: String = "会话内容"
    public const val PROVIDER_EFFORT_PLACEHOLDER: String = "可留空"

    // Semantic aliases: the literal already exists above; no second spelling is created.
    public const val PROVIDER_NAME_LABEL: String = MCP_FIELD_NAME
    public const val PROVIDER_KEY_LABEL: String = PROVIDER_KEY_SECTION
    public const val PROVIDER_IDENTIFIER_LABEL: String = PROVIDER_FIELD_ID
}
