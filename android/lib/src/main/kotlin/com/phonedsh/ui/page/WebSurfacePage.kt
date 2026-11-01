// Web surface: the full-screen host for the complete DSH Web page.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 row WebSurfacePage (完整 DSH 页面（WebView 宿主）;
// entry: RootView 的默认面（引擎就绪时）; exit: 全屏容器，不做返回栈), §3.1
// (the ScreenState layer), §5 rows `insets` and `ime`, and the startup/failure
// chrome in `RootView.swift`.
//
// The page has no harness event anchor: the engine, the WebView attachment and
// the loaded page are host reads, so §3.1 rule 3 makes the read-only snapshot the
// UiState-side input and `from(snapshot, local)` a pure function. The actual
// WebView is supplied by the host through `surface`; this file owns only the
// state chrome around it and never creates a WebView, reads a URL or waits on a
// network.
//
// The full-screen surface is the READY state only when the host says the engine,
// the WebView and the page are all present. Every other state shows a fallback
// panel:
//   * EMPTY: the host reported a snapshot but measured nothing;
//   * UNKNOWN: no snapshot was reported, so the page says 未知 and never "blank";
//   * FAILED: the host's last error, with retry / model settings / native
//     recovery, the three recovery paths the baseline offers;
//   * READY but not live: 正在准备本地引擎 plus the host's status line.
//
// Insets are consumed here directly rather than through `PageFrame`: §1 says the
// Web surface is a full-screen container with no navigation bar and no back
// stack, so a page header would not be parity. The frame still consumes
// `WindowInsets.safeDrawing` so no fallback text sits under a system bar.
// Android WebView has no `env(safe-area-inset-*)` equivalent, so the surface is
// inset rather than drawn edge-to-edge; this is recorded as an open question in
// the lane receipt.
//
// Geometry: page-level tokens only (`geometry.pageOuterMarginH`); every colour,
// space and type below is read through the theme locals.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * The host's read-only Web-surface snapshot.
 *
 * @param engine whether the local engine is running; unread when unknown.
 * @param webViewAttached whether the engine's WebView is attached to the surface.
 * @param pageLoaded whether the complete DSH page finished loading.
 * @param pageUrl the page's address, when the host exposes it.
 * @param statusLine the host's own startup line (for example 正在准备本地 DSH…).
 * @param nativeFallback whether the native recovery surface is available.
 * @param failure the host's last page error; non-null makes the state FAILED.
 */
@Immutable
public data class WebSurfaceSnapshot(
    public val engine: FactState = FactState.UNKNOWN,
    public val webViewAttached: FactState = FactState.UNKNOWN,
    public val pageLoaded: FactState = FactState.UNKNOWN,
    public val pageUrl: String? = null,
    public val statusLine: String? = null,
    public val nativeFallback: FactState = FactState.UNKNOWN,
    public val failure: String? = null,
) {
    /** True when at least one Web-surface fact was measured. */
    internal val hasMeasurement: Boolean
        get() = engine != FactState.UNKNOWN ||
            webViewAttached != FactState.UNKNOWN ||
            pageLoaded != FactState.UNKNOWN ||
            pageUrl != null ||
            statusLine != null ||
            nativeFallback != FactState.UNKNOWN ||
            failure != null
}

/**
 * The page's read-only input.
 *
 * @param snapshot the host's snapshot; `null` means the host did not report one.
 * @param failure the host's read failure; non-null when the last read failed.
 */
@Immutable
public data class WebSurfaceFacts(
    public val snapshot: WebSurfaceSnapshot? = null,
    public val failure: String? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** The four outcomes the surface distinguishes. */
public enum class WebSurfaceStatus {
    /** The host reported at least one fact; `live` says whether the surface may show. */
    READY,

    /** The host reported a snapshot but no fact in it was measured. */
    EMPTY,

    /** The last host read failed; the page offers the recovery paths. */
    FAILED,

    /** The host did not report a snapshot: the page says 未知, never "blank". */
    UNKNOWN,
}

/** One display-ready fact row in the status details. */
@Immutable
public data class WebSurfaceRowView(
    public val id: String,
    public val title: String,
    public val value: String,
    public val tone: PageTone,
)

/**
 * The complete Web-surface screen state.
 *
 * @param status the four-state outcome; FAILED wins because a failed read proves
 *   nothing about the surface.
 * @param live true only when READY and the host reports engine, WebView and page
 *   all present; only then is the host-supplied surface shown.
 * @param engine the engine fact, kept for the startup panel's wording.
 * @param preparing true for READY without [live], so the page shows the startup
 *   panel instead of a blank surface.
 * @param rows the engine/WebView/page/URL facts, shown in the status details.
 * @param statusLine the host's startup line, or `null` when unreported.
 * @param failure the failure message, or `null`.
 * @param detailsExpanded whether the user opened the fact rows.
 * @param hasUnmeasuredValues true when a fact row is 未知.
 */
@Immutable
public data class WebSurfaceScreenState(
    public val status: WebSurfaceStatus,
    public val live: Boolean,
    public val engine: FactState,
    public val preparing: Boolean,
    public val rows: List<WebSurfaceRowView>,
    public val statusLine: String?,
    public val failure: String?,
    public val detailsExpanded: Boolean,
    public val hasUnmeasuredValues: Boolean,
) {
    /** True when the host reported no snapshot. */
    public val isUnknown: Boolean get() = status == WebSurfaceStatus.UNKNOWN

    /** True when the host reported an empty snapshot. */
    public val isEmpty: Boolean get() = status == WebSurfaceStatus.EMPTY

    /** True when the last read failed. */
    public val isFailed: Boolean get() = status == WebSurfaceStatus.FAILED

    /**
     * A stable, display-free signature of the sequence-relevant state.
     *
     * The rows contribute their ids and tones, never their visible values, so an
     * A/B test can compare the sequence without depending on host copy.
     */
    public fun signature(): String = buildString {
        append(status.name).append(':')
        append(engine.name).append(':')
        append(if (live) "live" else "chrome").append(':')
        append(if (preparing) "preparing" else "settled").append(':')
        append(if (detailsExpanded) "details" else "collapsed").append(':')
        append(if (hasUnmeasuredValues) "partial" else "complete").append(':')
        append(rows.joinToString(",") { "${it.id}=${it.tone.name}" })
    }

    public companion object {
        public const val ENGINE_ROW_ID: String = "websurface.engine"
        public const val WEBVIEW_ROW_ID: String = "websurface.webview"
        public const val PAGE_ROW_ID: String = "websurface.page"
        public const val URL_ROW_ID: String = "websurface.url"
        public const val NATIVE_FALLBACK_ROW_ID: String = "websurface.native"

        /**
         * Projects (facts, local script) into the screen state.
         *
         * Pure: no clock, no URL fetch and no WebView call. The host supplies the
         * startup line and the URL, so the same facts and the same details script
         * always yield the same state sequence (§3.1).
         */
        public fun from(
            facts: WebSurfaceFacts,
            local: WebSurfaceLocalState = WebSurfaceLocalState(),
        ): WebSurfaceScreenState {
            val snapshot = facts.snapshot
            val failure = facts.failure ?: snapshot?.failure
            val status = when {
                failure != null -> WebSurfaceStatus.FAILED
                snapshot == null -> WebSurfaceStatus.UNKNOWN
                !snapshot.hasMeasurement -> WebSurfaceStatus.EMPTY
                else -> WebSurfaceStatus.READY
            }
            if (status == WebSurfaceStatus.FAILED) {
                return WebSurfaceScreenState(
                    status = status,
                    live = false,
                    engine = snapshot?.engine ?: FactState.UNKNOWN,
                    preparing = false,
                    rows = emptyList(),
                    statusLine = snapshot?.statusLine,
                    failure = failure,
                    detailsExpanded = false,
                    hasUnmeasuredValues = false,
                )
            }
            if (status == WebSurfaceStatus.UNKNOWN) {
                return WebSurfaceScreenState(
                    status = status,
                    live = false,
                    engine = FactState.UNKNOWN,
                    preparing = false,
                    rows = emptyList(),
                    statusLine = null,
                    failure = null,
                    detailsExpanded = false,
                    hasUnmeasuredValues = false,
                )
            }
            if (status == WebSurfaceStatus.EMPTY) {
                return WebSurfaceScreenState(
                    status = status,
                    live = false,
                    engine = FactState.UNKNOWN,
                    preparing = false,
                    rows = emptyList(),
                    statusLine = null,
                    failure = null,
                    detailsExpanded = false,
                    hasUnmeasuredValues = false,
                )
            }
            val measured = requireNotNull(snapshot)
            val rows = listOf(
                WebSurfaceRowView(
                    id = ENGINE_ROW_ID,
                    title = UiStrings.WEB_SURFACE_ENGINE,
                    value = when (measured.engine) {
                        FactState.YES -> UiStrings.WEB_SURFACE_ENGINE_READY
                        FactState.NO -> UiStrings.WEB_SURFACE_ENGINE_STOPPED
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    tone = when (measured.engine) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.NORMAL
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                ),
                WebSurfaceRowView(
                    id = WEBVIEW_ROW_ID,
                    title = UiStrings.WEB_SURFACE_WEBVIEW,
                    value = when (measured.webViewAttached) {
                        FactState.YES -> UiStrings.WEB_SURFACE_ATTACHED
                        FactState.NO -> UiStrings.WEB_SURFACE_NOT_ATTACHED
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    tone = when (measured.webViewAttached) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.NORMAL
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                ),
                WebSurfaceRowView(
                    id = PAGE_ROW_ID,
                    title = UiStrings.WEB_SURFACE_PAGE,
                    value = when (measured.pageLoaded) {
                        FactState.YES -> UiStrings.WEB_SURFACE_PAGE_LOADED
                        FactState.NO -> UiStrings.WEB_SURFACE_PAGE_LOADING
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    tone = when (measured.pageLoaded) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.NORMAL
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                ),
                WebSurfaceRowView(
                    id = URL_ROW_ID,
                    title = UiStrings.WEB_SURFACE_URL,
                    value = measured.pageUrl?.takeUnless { it.isBlank() } ?: UiStrings.UNKNOWN,
                    tone = if (measured.pageUrl.isNullOrBlank()) PageTone.UNKNOWN else PageTone.NORMAL,
                ),
                WebSurfaceRowView(
                    id = NATIVE_FALLBACK_ROW_ID,
                    title = UiStrings.WEB_SURFACE_NATIVE_RECOVERY,
                    value = when (measured.nativeFallback) {
                        FactState.YES -> UiStrings.WEB_SURFACE_NATIVE_AVAILABLE
                        FactState.NO -> UiStrings.UNAVAILABLE
                        FactState.UNKNOWN -> UiStrings.UNKNOWN
                    },
                    tone = when (measured.nativeFallback) {
                        FactState.YES -> PageTone.ON
                        FactState.NO -> PageTone.DEGRADED
                        FactState.UNKNOWN -> PageTone.UNKNOWN
                    },
                ),
            )
            val live = measured.engine == FactState.YES &&
                measured.webViewAttached == FactState.YES &&
                measured.pageLoaded == FactState.YES
            return WebSurfaceScreenState(
                status = WebSurfaceStatus.READY,
                live = live,
                engine = measured.engine,
                preparing = !live && measured.engine != FactState.NO,
                rows = rows,
                statusLine = measured.statusLine?.takeUnless { it.isBlank() },
                failure = null,
                detailsExpanded = local.detailsExpanded,
                hasUnmeasuredValues = rows.any { it.tone == PageTone.UNKNOWN },
            )
        }
    }
}

/** The local UI events of the Web surface: only the details disclosure. */
public sealed interface WebSurfaceUiEvent {
    /** Open or close the status-detail rows. */
    public data object ToggleDetails : WebSurfaceUiEvent
}

/**
 * The details script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param detailsExpanded whether the status facts are visible.
 */
@Immutable
public data class WebSurfaceLocalState(
    public val detailsExpanded: Boolean = false,
) {
    /** Applies one local event. */
    public fun apply(event: WebSurfaceUiEvent): WebSurfaceLocalState = when (event) {
        WebSurfaceUiEvent.ToggleDetails -> copy(detailsExpanded = !detailsExpanded)
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The full-screen DSH Web surface.
 *
 * @param state the pure screen state (`WebSurfaceScreenState.from`).
 * @param surface the host-owned WebView container; rendered only when [state] is
 *   live.
 * @param modifier the caller's modifier.
 * @param onRetry retry the host start; `null` hides the action.
 * @param onOpenModelSettings open model-service settings; `null` hides the action.
 * @param onNativeRecovery switch to the native recovery surface; `null` hides it.
 * @param onToggleDetails open/close the status facts; `null` hides the toggle.
 */
@Composable
public fun WebSurfacePage(
    state: WebSurfaceScreenState,
    surface: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onOpenModelSettings: (() -> Unit)? = null,
    onNativeRecovery: (() -> Unit)? = null,
    onToggleDetails: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    // `colors.background` is tier: unmeasured, so an unspecified value leaves the
    // platform surface in place instead of an invented sRGB fill.
    val background = if (tokens.colors.background.isSpecified) {
        Modifier.background(tokens.colors.background)
    } else {
        Modifier
    }
    Box(
        modifier = modifier
            .fillMaxSize()
            .then(background)
            // targetSdk 35 is edge-to-edge; Android WebView has no
            // env(safe-area-inset-*), so the surface and the panel are inset here.
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .testTag(UiPageTags.WEB_SURFACE_ROOT),
    ) {
        if (state.live) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiPageTags.WEB_SURFACE_SURFACE)
                    .semantics {
                        contentDescription = UiStrings.WEB_SURFACE_SURFACE_LABEL
                    },
            ) {
                surface()
            }
        } else {
            WebSurfaceChrome(
                state = state,
                onRetry = onRetry,
                onOpenModelSettings = onOpenModelSettings,
                onNativeRecovery = onNativeRecovery,
                onToggleDetails = onToggleDetails,
            )
        }
    }
}

/** The startup/failure/unknown panel; a scrollable list so every line is reachable. */
@Composable
private fun WebSurfaceChrome(
    state: WebSurfaceScreenState,
    onRetry: (() -> Unit)?,
    onOpenModelSettings: (() -> Unit)?,
    onNativeRecovery: (() -> Unit)?,
    onToggleDetails: (() -> Unit)?,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.WEB_SURFACE_LIST),
        verticalArrangement = Arrangement.spacedBy(pageListGap),
    ) {
        item(key = "websurface.panel") {
            WebSurfacePanel(state = state)
        }
        when (state.status) {
            WebSurfaceStatus.EMPTY -> {
                item(key = "websurface.empty") {
                    InfoRow(
                        title = UiStrings.WEB_SURFACE_EMPTY,
                        value = null,
                        subtitle = UiStrings.WEB_SURFACE_EMPTY_HINT,
                        modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_EMPTY),
                    )
                }
            }

            WebSurfaceStatus.UNKNOWN -> {
                item(key = "websurface.unknown") {
                    InfoRow(
                        title = UiStrings.WEB_SURFACE_UNKNOWN_STATE,
                        value = null,
                        subtitle = UiStrings.WEB_SURFACE_UNKNOWN_HINT,
                        modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_UNKNOWN),
                    )
                }
                item(key = "websurface.unknown.detail") {
                    InfoRow(
                        title = UiStrings.UNKNOWN,
                        value = null,
                        subtitle = UiStrings.WEB_SURFACE_UNKNOWN_DETAIL,
                        tone = PageTone.UNKNOWN,
                        modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_UNKNOWN_DETAIL),
                    )
                }
            }

            WebSurfaceStatus.FAILED -> {
                item(key = "websurface.failure") {
                    InfoRow(
                        title = UiStrings.WEB_SURFACE_FAILED,
                        value = null,
                        subtitle = state.failure ?: UiStrings.WEB_SURFACE_FAILED_HINT,
                        tone = PageTone.DEGRADED,
                        modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_FAILURE),
                    )
                }
                item(key = "websurface.failure.hint") {
                    WebSurfaceNoteRow(text = UiStrings.WEB_SURFACE_FAILED_HINT)
                }
            }

            WebSurfaceStatus.READY -> Unit
        }
        if (state.rows.isNotEmpty() && state.detailsExpanded) {
            items(count = state.rows.size, key = { index -> state.rows[index].id }) { index ->
                val row = state.rows[index]
                InfoRow(
                    title = row.title,
                    value = row.value,
                    tone = row.tone,
                    modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_ROW_PREFIX + row.id),
                )
            }
        }
        if (state.rows.isNotEmpty() && onToggleDetails != null) {
            item(key = "websurface.details.toggle") {
                InfoRow(
                    title = if (state.detailsExpanded) {
                        UiStrings.WEB_SURFACE_DETAILS_HIDE
                    } else {
                        UiStrings.WEB_SURFACE_DETAILS_SHOW
                    },
                    value = null,
                    onClick = onToggleDetails,
                    modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_DETAILS_TOGGLE),
                )
            }
        }
        if (state.hasUnmeasuredValues && state.detailsExpanded) {
            item(key = "websurface.unmeasured") {
                InfoRow(
                    title = UiStrings.UNKNOWN,
                    value = null,
                    subtitle = UiStrings.WEB_SURFACE_UNMEASURED_HINT,
                    tone = PageTone.UNKNOWN,
                    modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_UNMEASURED),
                )
            }
        }
        if (onRetry != null) {
            item(key = "websurface.retry") {
                InfoRow(
                    title = UiStrings.WEB_SURFACE_RETRY,
                    value = null,
                    onClick = onRetry,
                    modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_RETRY),
                )
            }
        }
        if (onOpenModelSettings != null) {
            item(key = "websurface.model") {
                InfoRow(
                    title = UiStrings.WEB_SURFACE_MODEL_SETTINGS,
                    value = null,
                    onClick = onOpenModelSettings,
                    modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_MODEL_SETTINGS),
                )
            }
        }
        if (onNativeRecovery != null) {
            item(key = "websurface.recovery") {
                InfoRow(
                    title = UiStrings.WEB_SURFACE_NATIVE_RECOVERY,
                    value = null,
                    onClick = onNativeRecovery,
                    modifier = Modifier.testTag(UiPageTags.WEB_SURFACE_NATIVE_RECOVERY),
                )
            }
        }
    }
}

/**
 * The one heading of the fallback panel: what the state is, in the state's ink.
 * It is not a second copy source; every word comes from `UiStrings`.
 */
@Composable
private fun WebSurfacePanel(state: WebSurfaceScreenState) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val title = when (state.status) {
        WebSurfaceStatus.READY -> if (state.engine == FactState.NO) {
            UiStrings.WEB_SURFACE_ENGINE_STOPPED
        } else {
            UiStrings.WEB_SURFACE_PREPARING
        }
        WebSurfaceStatus.EMPTY -> UiStrings.WEB_SURFACE_EMPTY
        WebSurfaceStatus.FAILED -> UiStrings.WEB_SURFACE_FAILED
        WebSurfaceStatus.UNKNOWN -> UiStrings.WEB_SURFACE_UNKNOWN_STATE
    }
    val subtitle = when (state.status) {
        WebSurfaceStatus.READY -> state.statusLine ?: UiStrings.WEB_SURFACE_PREPARING_HINT
        WebSurfaceStatus.EMPTY -> UiStrings.WEB_SURFACE_EMPTY_HINT
        WebSurfaceStatus.FAILED -> state.failure ?: UiStrings.WEB_SURFACE_FAILED_HINT
        WebSurfaceStatus.UNKNOWN -> UiStrings.WEB_SURFACE_UNKNOWN_HINT
    }
    val ink = when (state.status) {
        WebSurfaceStatus.FAILED -> tokens.colors.danger
        WebSurfaceStatus.UNKNOWN, WebSurfaceStatus.EMPTY -> tokens.colors.tertiary
        WebSurfaceStatus.READY -> tokens.colors.primary
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.WEB_SURFACE_PANEL)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = title,
            style = type.headline.copy(color = ink),
            modifier = Modifier
                .then(
                    if (state.status == WebSurfaceStatus.READY) {
                        Modifier.testTag(UiPageTags.WEB_SURFACE_PREPARING)
                    } else {
                        Modifier
                    },
                )
                .semantics { heading() },
        )
        BasicText(
            text = subtitle,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
        BasicText(
            text = UiStrings.WEB_SURFACE_SURFACE_LABEL,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/** One explanatory line; the ink is a token, never a second colour source. */
@Composable
private fun WebSurfaceNoteRow(text: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** Every token this file reads; kept equal to the source by `PageTokenReferenceTest`. */
internal object WebSurfacePageTokens {
    val refs: List<String> = listOf(
        "colors.background",
        "colors.danger",
        "colors.primary",
        "colors.secondary",
        "colors.tertiary",
        "geometry.pageOuterMarginH",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "typography.caption",
        "typography.headline",
        "typography.secondary",
    )
}
