// The 27 named states the iOS baseline publishes, under their Android names.
// SPDX-License-Identifier: MIT
//
// `docs/receipts/ios-baseline-screens/` holds 27 PNGs; every one of them is a
// *state*, not a page, and the file name is the state id. This registry is the
// Android side of that contract: one entry per iOS file, the Android capture name
// it is stored under, the page it renders, who owns making the state faithful,
// and whether this lane has captured it at the parity viewport yet.
//
// Naming rule (the mapping the README documents):
//
//   ios-chat-default        -> page-chat-default      (whole page, chat family)
//   ios-sessions-<state>    -> page-sessions-<state>  (whole page, list family)
//   ios-settings-<page>     -> page-settings-<page>   (settings subpage)
//   ios-code-block          -> surface-code-block     (a component swatch)
//   ios-environment-home    -> env-home               (not an app page)
//
// The first segment names the capture kind (`page-`/`surface-`/`env-`), the rest
// is the iOS state id with `ios-` replaced. Two states keep a `-default` suffix
// that iOS spells as the bare page (`ios-settings` -> `page-settings-default`)
// because the gate profile already owns `page-settings.png`.
//
// A `PENDING` entry is not a TODO in disguise: it is a named target with an
// owner, so the gap between Android and iOS is a list instead of a surprise. The
// capture script refuses to treat a partial registry as complete.
//
// Two categories, one registry file:
//
//   parity       an iOS baseline exists. Exactly 27 entries, `iosFile` must be a
//                real file in `docs/receipts/ios-baseline-screens/`, and the iOS
//                directory may not contain an unregistered state. This is the
//                cross-platform contract, so it stays exact.
//   androidOnly  an Android state with no iOS baseline (a page iOS never shipped,
//                or a surface the iOS baseline does not cover). Count is free,
//                `iosFile` is `none`, and the note must open with
//                `no iOS baseline:` so a reader learns *why* it is here.
//
// Keeping them in one file makes the two kinds of state visible side by side;
// keeping them in two categories stops the loose one from weakening the 27
// invariant (a single table holding both is how "30 != 27" turns into a false
// alarm against a lane that did nothing wrong).
package com.phonedsh.ui.screenshot

/**
 * The registry contract both categories implement: one line per state, `|`-separated.
 *
 * The line is `category|androidName|iosFile|status|owner|screen|note`; the host
 * parses it, so a note may not contain `|` or a newline.
 */
sealed interface CaptureState {
    /** [ParityCategory.PARITY] or [ParityCategory.ANDROID_ONLY]. */
    val category: ParityCategory

    /** The PNG name in the parity baseline directory. */
    val androidName: String

    /** The iOS baseline file, or `none` for an Android-only state. */
    val iosFile: String

    /** Whether this lane already captured it at the parity viewport. */
    val status: ParityStatus

    /** The lane that has to keep the state faithful. */
    val owner: String

    /** The page or component the state renders. */
    val screen: String

    /** What differs today / why there is no iOS baseline. */
    val note: String

    /** One pulled registry line. */
    fun registryLine(): String =
        listOf(category.id, androidName, iosFile, status.id, owner, screen, note).joinToString("|")
}

/** Which half of the registry an entry belongs to. */
enum class ParityCategory(
    /** The value in the pulled registry file. */
    val id: String,
) {
    /** An iOS baseline exists; the 27-entry invariants apply. */
    PARITY("parity"),

    /** Android-only: no iOS baseline, free count, `iosFile = none`. */
    ANDROID_ONLY("androidOnly"),
}

/**
 * One iOS baseline state, its Android capture name, and who owes the capture.
 *
 * @property androidName the PNG name in the parity baseline directory.
 * @property iosFile the file in `docs/receipts/ios-baseline-screens/`.
 * @property iosRoute the `-uiPreview` name the iOS baseline used (see its INDEX).
 * @property screen the page or component this state renders.
 * @property owner the lane that has to keep the state faithful.
 * @property status whether this lane already captured it at 402 x 874 @3.
 * @property note what differs today, for the owner; never contains `|` or a newline.
 */
enum class ParityState(
    override val androidName: String,
    override val iosFile: String,
    val iosRoute: String,
    override val screen: String,
    override val owner: String,
    override val status: ParityStatus,
    override val note: String,
) : CaptureState {
    // ------------------------------------------------------------------- chat
    PAGE_CHAT_DEFAULT(
        androidName = "page-chat-default",
        iosFile = "ios-chat-default",
        iosRoute = "sample",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "settled turn captured from ScreenshotSamples.chatState() under the header title " +
            "像素基线复盘; the iOS shot is a different conversation (its own 等待授权 card and " +
            "folded tool run), so the sheet compares chrome and geometry, not transcript content",
    ),
    PAGE_CHAT_ASSISTANT(
        androidName = "page-chat-assistant",
        iosFile = "ios-chat-assistant",
        iosRoute = "chat.assistant",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "one settled turn from ChatParitySamples.chatAssistant: user bubble, Read tool row " +
            "and one assistant answer carrying a swift code block, over the READY empty state",
    ),
    PAGE_CHAT_OFFICIAL(
        androidName = "page-chat-official",
        iosFile = "ios-chat-official",
        iosRoute = "chat.official",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "L84 transcribed the iOS sample (PreviewChatItems.official, NativeShell.swift:953-1040) " +
            "into ChatParitySamples.chatOfficial: user message, context, reasoning, bash, six edits " +
            "and the long answer (table, inline/display TeX, literal HTML, footnote, 已编辑 6 个文件 " +
            "card), so the sheet compares the renderer, not a content gap. Both sides open at the " +
            "transcript tail; the remaining offset is the page's transcript-to-composer gap (about " +
            "17 pt on this side), which is page geometry, not markdown",
    ),
    PAGE_CHAT_FAILED(
        androidName = "page-chat-failed",
        iosFile = "ios-chat-failed",
        iosRoute = "chat.failed",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "FAILED phase + retryable fail-loud banner; iOS draws a red 'not sent' line under " +
            "the last bubble, so the failure chrome is not the same component",
    ),
    PAGE_CHAT_QUEUED(
        androidName = "page-chat-queued",
        iosFile = "ios-chat-queued",
        iosRoute = "chat.queued",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "已排队 bubble badge captured; the 排队中 strip the iOS shot draws above the " +
            "composer is absent because chatQueued() builds ChatScreenState directly and leaves " +
            "ComposerState.queued empty (ChatScreenState.from() is what fills it), a sample gap " +
            "the sheet makes visible",
    ),
    PAGE_CHAT_LONG(
        androidName = "page-chat-long",
        iosFile = "ios-chat-long",
        iosRoute = "chat.long",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "6 long turns; only the first viewport is in frame (the harness captures no scroll " +
            "position), so this is a density state, not a scrolled-to-bottom state",
    ),
    PAGE_CHAT_DRAFT(
        androidName = "page-chat-draft",
        iosFile = "ios-chat-draft",
        iosRoute = "chat.draft",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "5000-character draft over the engine-not-started empty state; composer at its " +
            "declared max height",
    ),
    PAGE_CHAT_PERMISSION(
        androidName = "page-chat-permission",
        iosFile = "ios-chat-permission",
        iosRoute = "chat.permission",
        screen = "ChatPage",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "two permission cards from ChatParitySamples.chatPermission: 要写一个文件 primary " +
            "plus folded 要跑一条命令, pending block expanded, no transcript and no engine",
    ),

    // --------------------------------------------------------------- sessions
    PAGE_SESSIONS_DEFAULT(
        androidName = "page-sessions-default",
        iosFile = "ios-sessions-default",
        iosRoute = "sessions",
        screen = "SessionsPage",
        owner = "Sessions lane",
        status = ParityStatus.UNREACHABLE,
        note = "unreachable on a device: the page needs workspace facts and HostNavFacts.kt sets workspaces = null, so a real host draws the 未知 folder block instead of the 0-folder empty block. Sample: 0 sessions, 0 folders, engine off in the FULL 402 pt window (NativeShell.swift:842). Same state in the 320 pt drawer is page-sessions-nothing; since L73 the two captures differ exactly where the two iOS shots do",
    ),
    PAGE_SESSIONS_MANY(
        androidName = "page-sessions-many",
        iosFile = "ios-sessions-many",
        iosRoute = "sessions.many",
        screen = "SessionsPage",
        owner = "Sessions lane",
        status = ParityStatus.UNREACHABLE,
        note = "unreachable on a device: 40 sessions dealt across 2 folders needs workspace facts the host does not report (HostNavFacts.kt workspaces = null), so the folder sections cannot be drawn on a phone",
    ),
    PAGE_SESSIONS_EMPTY(
        androidName = "page-sessions-empty",
        iosFile = "ios-sessions-empty",
        iosRoute = "sessions.empty",
        screen = "SessionsPage",
        owner = "Sessions lane",
        status = ParityStatus.UNREACHABLE,
        note = "unreachable on a device: 0 sessions across 2 folders — the folder sections need workspace facts the host does not report (HostNavFacts.kt workspaces = null). This is the state L86 measured as 79.22 % of the frame away from the real first-run home",
    ),
    PAGE_SESSIONS_NOTHING(
        androidName = "page-sessions-nothing",
        iosFile = "ios-sessions-nothing",
        iosRoute = "sessions.nothing",
        screen = "SessionsPage",
        owner = "Sessions lane",
        status = ParityStatus.UNREACHABLE,
        note = "unreachable on a device: 0 folders is a workspace fact the host does not report (HostNavFacts.kt workspaces = null), so a phone draws the 未知 block here; the sample is 0 sessions / 0 folders in the baseline's DrawerPreview (.frame(width: 320), NativeShell.swift:872-879): the block centres on 160 and the CTA runs 16 → 304, so this capture is NOT page-sessions-default — the two differ by the container width, exactly like the two iOS PNGs",
    ),
    PAGE_SESSIONS_UNGROUPED(
        androidName = "page-sessions-ungrouped",
        iosFile = "ios-sessions-ungrouped",
        iosRoute = "sessions.ungrouped",
        screen = "SessionsPage",
        owner = "Sessions lane",
        status = ParityStatus.UNREACHABLE,
        note = "unreachable on a device: 3 sessions and *no folder* is a workspace fact; the host reports none, so a phone draws the 未知 folder block instead of the ungrouped rows",
    ),
    PAGE_SESSIONS_ERROR(
        androidName = "page-sessions-error",
        iosFile = "ios-sessions-error",
        iosRoute = "sessions.error",
        screen = "SessionsPage",
        owner = "Sessions lane",
        status = ParityStatus.CAPTURED,
        note = "one folder, two rows, and the host's 读不到会话 failure line with 重试",
    ),
    PAGE_SESSIONS_SCHEDULES(
        androidName = "page-sessions-schedules",
        iosFile = "ios-sessions-schedules",
        iosRoute = "sessions.schedules",
        screen = "NativeAutomationPage",
        owner = "Automation lane (L11)",
        status = ParityStatus.UNREACHABLE,
        note = "unreachable on a device: the host reports no schedule snapshot, so NativeAutomationPage draws 定时任务状态未知 / 未知 and no 新建任务 CTA (measured 91.87 % of the frame away from this sample). Sample keeps L11's alignment: 34 pt large title, ✕ + 刷新 leading, 新建 trailing, empty block with the 50 pt CTA, then 需要处理 with the host's raw error",
    ),

    // --------------------------------------------------------------- settings
    PAGE_SETTINGS_DEFAULT(
        androidName = "page-settings-default",
        iosFile = "ios-settings",
        iosRoute = "settings",
        screen = "SettingsPage (通用 tab)",
        owner = "Settings lane",
        status = ParityStatus.CAPTURED,
        note = "post-PR-13 five-tab shell: 44 pt bar (完成 trailing) + 32 pt segmented picker over " +
            "the 通用 tab's six inset-grouped cards; iOS has no section headers there, only two " +
            "footnotes, and Android adds a sixth card for the platform appendix",
    ),
    PAGE_SETTINGS_MODEL(
        androidName = "page-settings-model",
        iosFile = "ios-settings-model",
        iosRoute = "settings.model",
        screen = "SettingsPage (模型 tab) / ModelProviderSettingsPage embedded",
        owner = "Settings lane",
        status = ParityStatus.CAPTURED,
        note = "the 模型 tab is ModelProviderSettingsPage on both platforms; captured inside the " +
            "shell (picker above, no second bar). iOS shows a 34 pt 模型服务 title, 服务 / 生效方式 " +
            "headers, icon action rows and 2 separators",
    ),
    PAGE_SETTINGS_SEARCH(
        androidName = "page-settings-search",
        iosFile = "ios-settings-search",
        iosRoute = "settings.search",
        screen = "WebSearchSettingsPage",
        owner = "Settings lane",
        status = ParityStatus.CAPTURED,
        note = "preview-only on iOS HEAD (no settings tab opens it; 插件 > 插件配置 > 网页搜索与抓取 " +
            "does); 34 pt 网页搜索 + a radio form and three paragraphs = 4 separators on iOS",
    ),
    PAGE_SETTINGS_NETWORK(
        androidName = "page-settings-network",
        iosFile = "ios-settings-network",
        iosRoute = "settings.network",
        screen = "EgressAllowListPage",
        owner = "Settings lane",
        status = ParityStatus.CAPTURED,
        note = "preview-only on iOS HEAD (no settings tab opens it); allow-all off + 15 hosts at a " +
            "52.33 pt pitch with 11 separators in frame, centred inline 网络访问 title",
    ),
    PAGE_SETTINGS_PLUGINS(
        androidName = "page-settings-plugins",
        iosFile = "ios-settings-plugins",
        iosRoute = "settings.plugins",
        screen = "SettingsPage (插件 tab) / NativeConfigurationPage embedded",
        owner = "Settings lane",
        status = ParityStatus.CAPTURED,
        note = "the 插件 tab is NativePluginInventoryPage -> NativeConfigurationPage on iOS; " +
            "captured inside the shell. iOS: 34 pt 插件, three glass capsules, 6 separators",
    ),
    PAGE_SETTINGS_ABOUT(
        androidName = "page-settings-about",
        iosFile = "ios-settings-about",
        iosRoute = "settings.about",
        screen = "AboutPage",
        owner = "Settings lane",
        status = ParityStatus.CAPTURED,
        note = "preview-only on BOTH platforms (no route reaches it); captured from the page " +
            "directly, which is what the iOS DEBUG router does. iOS: 关于 inline title + one card " +
            "with 1 separator; Android adds 系统 / 更多 cards",
    ),
    PAGE_SETTINGS_RUNTIME(
        androidName = "page-settings-runtime",
        iosFile = "ios-settings-runtime",
        iosRoute = "settings.runtime",
        screen = "RuntimeDetailsPage",
        owner = "Settings lane",
        status = ParityStatus.CAPTURED,
        note = "preview-only after PR #13 (the iOS 设置 row is gone; chat's runtime sheet still " +
            "opens it); engine stopped, 34 pt 运行状态, 2 separators on iOS",
    ),

    // --------------------------------------------------------- workspace/files
    PAGE_WORKSPACE_FOLDERS(
        androidName = "page-workspace-folders",
        iosFile = "ios-workspace-folders",
        iosRoute = "workspace",
        screen = "WorkspaceFoldersPage",
        owner = "Shell/Files lane",
        status = ParityStatus.CAPTURED,
        note = "empty list + accent CTA captured; Android has no 34 pt large-title token (the " +
            "heading is 17 pt headline) and no glass toolbar button",
    ),
    PAGE_FILES(
        androidName = "page-files",
        iosFile = "ios-files",
        iosRoute = "workspace.files",
        screen = "FilesPage",
        owner = "Shell/Files lane",
        status = ParityStatus.CAPTURED,
        note = "empty workspace captured (grey capsule search + two-line card); Android has no " +
            "34 pt large-title token and the host reports no file listing, so the running app " +
            "shows the waiting state instead of this sample",
    ),
    PAGE_SHELL(
        androidName = "page-shell",
        iosFile = "ios-shell",
        iosRoute = "configuration",
        screen = "PDSHShellPage (body) / ToolsPage.kt (reducer)",
        owner = "Shell/Files lane",
        status = ParityStatus.CAPTURED,
        note = "grouped-card body landed and is routed (设置 → 命令); rows are 44 dp and type is " +
            "14/13 sp against the baseline's 51.3 pt rows / 17 pt labels",
    ),

    // -------------------------------------------------------------- component
    SURFACE_CODE_BLOCK(
        androidName = "surface-code-block",
        iosFile = "ios-code-block",
        iosRoute = "code.block",
        screen = "DSSCodeBlock swatch",
        owner = "Chat lane",
        status = ParityStatus.CAPTURED,
        note = "the code block is not a standalone surface in :lib, so the capture draws the " +
            "CodeBlock composable alone in a page-width column with the iOS long-line swatch " +
            "(ChatParitySamples.CODE_SWATCH), no header and no composer, like the iOS swatch",
    ),

    // ------------------------------------------------------------ environment
    ENV_HOME(
        androidName = "env-home",
        iosFile = "ios-environment-home",
        iosRoute = "(springboard, no app)",
        screen = "Android launcher",
        owner = "L0 capture (adb screencap)",
        status = ParityStatus.PENDING,
        note = "environment proof, not an app page: capture with `adb exec-out screencap -p`, " +
            "which the Compose harness cannot do",
    ),
    ;

    override val category: ParityCategory get() = ParityCategory.PARITY

    companion object {
        /** The iOS baseline directory publishes exactly this many states. */
        const val IOS_BASELINE_STATE_COUNT: Int = 27

        /** States this lane has already captured at the parity viewport. */
        fun captured(): List<ParityState> =
            ParityState.entries.filter { it.status == ParityStatus.CAPTURED }

        /** States a page lane still owes. */
        fun pending(): List<ParityState> =
            ParityState.entries.filter { it.status == ParityStatus.PENDING }
    }
}

/**
 * Android states with **no iOS baseline**: registered so they have a legitimate
 * home, outside the 27-entry invariant.
 *
 * Count is free on purpose. The only rules are: the name is unique across both
 * categories, [iosFile] is `none`, an owner exists, and [reason] opens with
 * `no iOS baseline:`.
 *
 * @property androidName the PNG name in the parity baseline directory.
 * @property owner the lane that owes the capture.
 * @property screen the page or component the state renders.
 * @property status whether it has been captured at 402 x 874 @3 yet.
 * @property reason why iOS has no baseline for it; must start with `no iOS baseline:`.
 */
enum class AndroidOnlyState(
    override val androidName: String,
    override val owner: String,
    override val screen: String,
    override val status: ParityStatus,
    val reason: String,
) : CaptureState {
    PAGE_DEVICE_CONNECTION(
        androidName = "page-device-connection",
        owner = "Device connector lane (L5)",
        screen = "NativeDeviceConnectionPage",
        status = ParityStatus.PENDING,
        reason = "no iOS baseline: the iOS 27-state baseline has no device-connector page " +
            "(the connector is an Android-local seam), so there is nothing to lay it next to",
    ),
    PAGE_DEVICE_SESSION(
        androidName = "page-device-session",
        owner = "Device connector lane (L5)",
        screen = "NativeDeviceSessionPage",
        status = ParityStatus.PENDING,
        reason = "no iOS baseline: reading a remote session transcript is not in the iOS " +
            "baseline set; the state is ours to define",
    ),
    PAGE_SESSION_ARTIFACTS(
        androidName = "page-session-artifacts",
        owner = "Device connector lane (L5)",
        screen = "SessionArtifactsPage",
        status = ParityStatus.PENDING,
        reason = "no iOS baseline: the artifacts list is an Android-only surface, so it is a " +
            "self-regression baseline with no cross-platform counterpart",
    ),
    ;

    override val category: ParityCategory get() = ParityCategory.ANDROID_ONLY

    /** The reason doubles as the note: for this category the note *is* the reason. */
    override val note: String get() = reason

    /** Always `none`: that is what "no iOS baseline" means here. */
    override val iosFile: String get() = NO_IOS_BASELINE

    companion object {
        /** The value [iosFile] takes for this category. */
        const val NO_IOS_BASELINE: String = "none"

        /** The prefix every [reason] must carry, so the host can check it. */
        const val REASON_PREFIX: String = "no iOS baseline:"
    }
}

/** Whether a state is capturable today, and by whom. */
enum class ParityStatus(
    /** The value in the pulled registry file. */
    val id: String,
) {
    /** Captured by this lane at 402 x 874 @3; the PNG is in the parity baseline dir. */
    CAPTURED("captured"),

    /** Registered and owned, not captured yet: the page lane supplies the state. */
    PENDING("pending"),

    /**
     * Captured, but **the running app cannot produce this state**: the host does
     * not report the facts the page needs, so the capture is a sample the device
     * will never show.
     *
     * The value exists because "captured" was doing two jobs. A state that is
     * faithful to the page but unreachable from the host used to read exactly
     * like one the app really draws, and a reviewer reading the sheet had no way
     * to tell them apart. L86 measured the difference on a device (see
     * `docs/receipts/ui-parity-sheet/real-device/REPORT.md`): the folder-section
     * states need workspace facts `HostNavFacts.kt` sets to `null`, and the
     * automation state needs a schedule snapshot the host never reports.
     */
    UNREACHABLE("unreachable"),
}

/**
 * The complete registry a host verifies: both categories, in registry order.
 *
 * Every parity suite publishes with this function instead of writing
 * `ParityState.entries` itself. The registry is one file, so whichever suite's
 * `@Before` runs last owns its contents; a suite that wrote only the 27 parity
 * rows would silently drop the `androidOnly` section (the host would then see
 * "0 androidOnly states" and could not notice a device state going missing).
 */
fun captureRegistryLines(): List<String> =
    (ParityState.entries + AndroidOnlyState.entries).map { it.registryLine() }
