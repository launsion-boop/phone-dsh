// PR22 home drawer presentation facts and stable local fold state.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

/** Host reported session row. A missing title/time stays visibly unknown. */
public data class HomeDrawerSession(
    public val id: String,
    public val title: String?,
    public val relativeTime: String? = null,
    public val running: Boolean = false,
)

/** Host reported folder and its session membership/order. */
public data class HomeDrawerFolder(
    public val id: String,
    public val title: String,
    public val sessions: List<HomeDrawerSession> = emptyList(),
    public val isDefault: Boolean = false,
)

/** Engine status shown in the pinned settings bar. */
public enum class HomeDrawerEngineState(public val label: String) {
    STARTING("引擎启动中"), STOPPED("引擎未启动"), CONFIGURATION_REQUIRED("待配置模型"),
    RUNNING("运行中"), READY("引擎就绪"), UNKNOWN("状态未知"),
}

/** Session/folder lists are nullable because an unread host is not an empty host. */
public data class HomeDrawerFacts(
    public val folders: List<HomeDrawerFolder>? = null,
    public val unassignedSessions: List<HomeDrawerSession>? = null,
    public val activeSessionId: String? = null,
    public val scheduleCount: Int? = null,
    public val engine: HomeDrawerEngineState = HomeDrawerEngineState.UNKNOWN,
    public val newSessionBlockedReason: String? = null,
    /** Actual session/folder snapshot failure, if the host read failed. */
    public val failure: String? = null,
)

/** One archive request passed from the drawer to its host adapter. */
public data class HomeDrawerArchiveRequest(
    public val requestId: String,
    public val sessionId: String,
)

/**
 * The host's correlated archive response. A success must mean the host confirms
 * the write (or reread), not merely that it accepted an asynchronous request.
 */
public sealed interface HomeDrawerArchiveResult {
    public val requestId: String
    public val sessionId: String

    /** Confirmed archived for this exact request and session. */
    public data class Archived(
        override val requestId: String,
        override val sessionId: String,
    ) : HomeDrawerArchiveResult

    /** The host reports that the archive did not complete; retry remains possible. */
    public data class Failed(
        override val requestId: String,
        override val sessionId: String,
        public val reason: String,
    ) : HomeDrawerArchiveResult

    /** The host cannot perform the write. */
    public data class Unavailable(
        override val requestId: String,
        override val sessionId: String,
        public val reason: String? = null,
    ) : HomeDrawerArchiveResult
}

/**
 * Prototype bridge until the canonical B/H host exposes a matching archive
 * receipt. Do not adapt `ProbeEngineViewModel.archiveChatSession`'s Boolean to
 * [HomeDrawerArchiveResult.Archived]: it reports request acceptance while the
 * metadata write runs asynchronously. The canonical adapter must return an
 * [HomeDrawerArchiveResult] matching both request id and session id.
 */
public typealias HomeDrawerArchiveAction = suspend (HomeDrawerArchiveRequest) -> HomeDrawerArchiveResult

/** Typed host mutation callback used for durable folder and session metadata edits. */
public typealias HomeDrawerMutationAction = suspend (PdshUiHostCommand) -> PdshActionReceipt?

/**
 * Stable preference key shared with the app's canonical PreferenceStore.
 * The UI module owns no separate persistence; the host supplies and confirms it.
 */
public object HomeDrawerState {
    public const val COLLAPSED_FOLDERS_KEY: String = "phone-dsh.sidebar.collapsed-workspaces"
}
