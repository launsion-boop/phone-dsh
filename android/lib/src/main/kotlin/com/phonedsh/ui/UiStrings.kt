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
    public const val SETTINGS_ROW_BACKGROUND: String = "后台运行"
    public const val SETTINGS_ROW_NETWORK: String = "网络访问"
    public const val SETTINGS_ROW_PLUGINS: String = "插件与模型"
    public const val SETTINGS_ROW_SEND: String = "发送消息时"
    public const val SETTINGS_ROW_EXPORT: String = "导出诊断"

    // Android has no LicensesPage: the iOS one lists SwiftTerm and swift-nio.
    public const val SETTINGS_LICENSES_ANDROID_ONLY: String =
        "iOS 依赖的许可清单在 Android 不适用（这个 App 没有 SwiftTerm / swift-nio）。"

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
    public const val PERMISSION_DEFAULTS_NOTE: String = "只影响之后新开的会话。正在聊的这个不跟着变。"
    public const val PERMISSION_TIER_VIEW_ONLY: String = "仅可查看"
    public const val PERMISSION_TIER_WORKSPACE_WRITE: String = "工作区内修改"
    public const val PERMISSION_TIER_FULL_ACCESS: String = "完全权限"

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
    public const val WORKBENCH_TITLE: String = "工作面板"
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
    public const val WORKSPACE_EMPTY_HINT: String = "新建一个文件夹，会话和文件都放在里面"
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
    public const val PROVIDER_EFFECT: String = "配置从下一次启动引擎起生效"

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
    public const val RUNTIME_TITLE: String = "运行时详情"
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

    // EgressAllowListPage: the effective rules, the deny-all empty table and
    // the matching form each entry stands for.
    /**
     * 与设置行文案一致，见 `spec/ui/v1/README.md` §1（设置内「出网白名单」）：
     * 同一个名字既是设置行的入口文案，也是本页标题，两处不再各写一套。
     */
    public const val EGRESS_TITLE: String = "出网白名单"
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
    public const val AUTOMATION_EMPTY_HINT: String = "到点让它自己跑，结果回到原会话。"
    public const val AUTOMATION_NEW: String = "新建任务"
    public const val AUTOMATION_EDIT: String = "编辑任务"
    public const val AUTOMATION_REFRESH: String = "刷新"
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
    public const val AUTOMATION_PLANNED_AT_FORMAT: String = "计划时间 %s"
    public const val AUTOMATION_META_FORMAT: String = "%s · %s"

    // NativeConfigurationPage: the session-level settings groups and the plugin
    // inventory. Values are host-formatted; an unread value is 未知.
    public const val CONFIGURATION_TITLE: String = "本会话设置"
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
    public const val PROBES_TITLE: String = "设备探针"
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
    public const val BACKGROUND_TITLE: String = "后台保活"
    public const val BACKGROUND_SECTION_RUN: String = "运行"
    public const val BACKGROUND_SECTION_OBSERVATION: String = "观测"
    public const val BACKGROUND_SECTION_CELLS: String = "矩阵结果"
    public const val BACKGROUND_SECTION_TRANSITIONS: String = "迁移记录"
    public const val BACKGROUND_SCENARIO: String = "场景"
    public const val BACKGROUND_SCENARIO_BACKGROUND: String = "退到后台"
    public const val BACKGROUND_SCENARIO_LOCK: String = "锁屏"
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
    public const val TASK_SCREEN_TITLE: String = "任务屏"
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
    public const val EXPORT_TITLE: String = "导出诊断包"
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
    public const val DAILY_BRIEF_ITEMS_EMPTY_SOURCES: String = "下拉或点刷新；失败时不会清空上一期。"
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
    public const val BACKGROUND_WINDOW_10MIN: String = "10 分钟（PLAN）"
    public const val BACKGROUND_WINDOW_60S: String = "60 秒（UI 检查）"
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
    public const val HEADER_MORE: String = "更多操作"
    public const val HEADER_EXPORT: String = "导出对话记录"
    public const val HEADER_SESSION_SETTINGS: String = "本会话设置"
    public const val SESSION_TITLE_NEW: String = "新会话"
    public const val SESSION_TITLE_CURRENT: String = "当前会话"
    public const val RENAME_DIALOG_TITLE: String = "重命名会话"
    public const val RENAME_FIELD: String = "会话名称"
    public const val RENAME_SAVE: String = "保存"

    // Failure surfaces (ChatPage.swift `errorBanner` / `failureLine`).
    public const val SEND_FAILED_LINE: String = "没发出去"
    public const val DOT_SEPARATOR: String = "·"
    public const val CLOSE_HINT: String = "关闭提示"

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

    // Message actions (NativeMessageActions.swift) and attachments.
    public const val MESSAGE_COPY: String = "复制"
    public const val MESSAGE_COPIED: String = "已复制"

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
}
