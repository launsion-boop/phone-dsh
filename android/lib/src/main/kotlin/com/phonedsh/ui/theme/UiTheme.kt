// The Compose theme: the only place the UI reads a token value from.
// SPDX-License-Identifier: MIT
//
// `typography.scale` says rendering = baseSize x platform scale and the token
// stores no absolute unit. On Android that rule is implemented by emitting the
// base size in `sp`: the framework multiplies every `sp` by `fontScale`, so the
// UI never computes a scaled number itself and a changed font scale reaches the
// layout (line heights grow, nothing is clipped). See the `font-scale` row of
// `spec/ui/v1/README.md` §5.
package com.phonedsh.ui.theme

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.View
import android.view.Window
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalInspectionMode
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import com.phonedsh.ui.theme.generated.TokenType
import com.phonedsh.ui.theme.generated.UiTokenData
import kotlin.math.max

/**
 * User typographic preferences from the host's persisted settings.
 *
 * The values are base points, never pre-scaled: [UiType.applyPreferences] keeps
 * the token's size/line-height ratio and the platform font scale remains the
 * only multiplier. A `null` field keeps the reviewed PR22 default, so a fresh
 * install renders body 16/24, code 14 and terminal 13 (the source defaults in
 * `NativeChatPreferences.swift:47-53`).
 */
@Immutable
public data class UiTypePreferences(
    public val textSizePt: Float? = null,
    public val codeSizePt: Float? = null,
    public val terminalSizePt: Float? = null,
    public val textFontFamily: FontFamily? = null,
    public val codeFontFamily: FontFamily? = null,
    public val terminalFontFamily: FontFamily? = null,
)

/** The parity typography roles plus the appended PR22 HomeSpec roles. */
@Immutable
public data class UiType(
    public val body: TextStyle,
    public val secondary: TextStyle,
    public val caption: TextStyle,
    public val code: TextStyle,
    public val codeLabel: TextStyle,
    public val codeAction: TextStyle,
    public val codeExpand: TextStyle,
    public val shimmer: TextStyle,
    public val jsonLabel: TextStyle,
    public val jsonBody: TextStyle,
    /** iOS `.titleMedium` mapping. */
    public val headline: TextStyle,
    /** iOS `.titleSmall` mapping. */
    public val subheadline: TextStyle,
    /** iOS `.largeTitle` (34/700); the settings index reads it. */
    public val largeTitle: TextStyle,
    /** Grouped settings row label; the canonical 16/24 body token. */
    public val rowLabel: TextStyle,
    /** General code preference role; fresh default 14, user override preserved. */
    public val controlBody: TextStyle,
    /** Compatibility alias to `.largeTitle` for empty-state titles. */
    public val emptyStateTitle: TextStyle,
    // ---- PR22 HomeSpec type roles (430x932pt) ----------------------------
    // Appended after the parity roles so no earlier position shifts. Sizes,
    // weights and line boxes all come from reviewed `spec/ui/v1/tokens.json`.
    /** Nav title: 17.5 / 600 / 22. */
    public val navTitle: TextStyle,
    /** Nav subtitle (folder name): 14.5 / 400 / 20. */
    public val navSubtitle: TextStyle,
    /**
     * PR22 home body: 16 / 24.
     *
     * This is the same canonical value as [body]; [body] itself is 16/24 now so
     * a page that predates the explicit `homeBody` role also renders the PR22
     * size instead of the retired 17 pt parity default.
     */
    public val homeBody: TextStyle,
    /** Process row: 15 / 400 / 24. */
    public val processBody: TextStyle,
    /** Step-list row: 14 / 400 / 22. */
    public val listItem: TextStyle,
    /** Primary pill label: 16 / 600. */
    public val buttonLabel: TextStyle,
    /** Tag: 12 / 500. */
    public val tagLabel: TextStyle,
    /** Tab bar label: 10.5 / 500 / 14 (retained; the home uses a drawer). */
    public val tabLabel: TextStyle,
    /** Fresh terminal preference default: 13 pt monospaced; user override preserved. */
    public val terminal: TextStyle,
    /** Secondary UIKit navigation title: 17 / 600, distinct from in-page 17.5 navTitle. */
    public val pageTitle: TextStyle,
) {
    public companion object {
        /** Builds the styles from `typography.styles`; `sp` carries the system font scale. */
        public fun fromSpec(): UiType = UiType(
            body = UiTokenData.typeBody.style(),
            secondary = UiTokenData.typeSecondary.style(),
            caption = UiTokenData.typeCaption.style(),
            code = UiTokenData.typeCode.style(),
            codeLabel = UiTokenData.typeCodeLabel.style(),
            codeAction = UiTokenData.typeCodeAction.style(),
            codeExpand = UiTokenData.typeCodeExpand.style(),
            // Compatibility roles resolve through declared aliases, never a
            // second hand-typed style table.
            shimmer = UiTokenData.typeProcess.style(),
            jsonLabel = UiTokenData.typeTagLabel.style(),
            jsonBody = UiTokenData.typeCode.style(),
            headline = UiTokenData.typeNavTitle.style(),
            subheadline = UiTokenData.typeNavSubtitle.style(),
            largeTitle = UiTokenData.typeLargeTitle.style(),
            rowLabel = UiTokenData.typeBody.style(),
            controlBody = UiTokenData.typeCode.style(),
            emptyStateTitle = UiTokenData.typeLargeTitle.style(),
            navTitle = UiTokenData.typeNavTitle.style(),
            navSubtitle = UiTokenData.typeNavSubtitle.style(),
            homeBody = UiTokenData.typeBody.style(),
            processBody = UiTokenData.typeProcess.style(),
            listItem = UiTokenData.typeListItem.style(),
            buttonLabel = UiTokenData.typeButtonLabel.style(),
            tagLabel = UiTokenData.typeTagLabel.style(),
            tabLabel = UiTokenData.typeTabLabel.style(),
            terminal = UiTokenData.typeTerminal.style(),
            pageTitle = UiTokenData.typePageTitle.style(),
        )
    }
}

/**
 * Applies persisted user sizes to the reviewed roles.
 *
 * Only the roles the host actually persists are touched: body/homeBody share
 * the text preference, [code]/[controlBody]/[jsonBody] share the code
 * preference and [terminal] keeps its own. A preference equal to the reviewed
 * default is a no-op, so the 16/24, 14 and 13 source values remain exact.
 */
public fun UiType.applyPreferences(preferences: UiTypePreferences): UiType {
    if (preferences.textSizePt == null && preferences.codeSizePt == null &&
        preferences.terminalSizePt == null && preferences.textFontFamily == null &&
        preferences.codeFontFamily == null && preferences.terminalFontFamily == null
    ) return this
    fun TextStyle.withSize(sizePt: Float?, family: FontFamily?, minimumLineHeightPt: Float? = null): TextStyle {
        if (sizePt == null) return if (family == null) this else copy(fontFamily = family)
        val base = fontSize.value
        val ratio = if (fontSize.isSp && base > 0f) lineHeight.value / base else 0f
        return copy(
            fontSize = sizePt.sp,
            lineHeight = if (ratio > 0f) max(minimumLineHeightPt ?: sizePt, sizePt * ratio).sp else lineHeight,
            fontFamily = family ?: fontFamily,
        )
    }
    val textBody = body.withSize(preferences.textSizePt, preferences.textFontFamily, minimumLineHeightPt = 24f)
    val codeRole = code.withSize(preferences.codeSizePt, preferences.codeFontFamily)
    return copy(
        body = textBody,
        homeBody = textBody,
        rowLabel = textBody,
        // NativeChatTheme.secondaryFont/captionFont are fixed system roles, not
        // user-preference roles; the text preference does not resize them.
        code = codeRole,
        controlBody = codeRole,
        jsonBody = codeRole,
        // Code toolbar labels/actions are fixed component roles, not the code
        // preference: NativeChatTheme.codeFont() only feeds code blocks.
        terminal = terminal.withSize(preferences.terminalSizePt, preferences.terminalFontFamily),
    )
}

/** `baseSize` is emitted in `sp` so the platform scale is the only multiplier. */
internal fun TokenType.style(): TextStyle = TextStyle(
    fontSize = baseSize.sp,
    fontWeight = FontWeight(weight),
    fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
    // HomeSpec's 16/24, 14/22, 17.5/22 roles carry an explicit line box; roles
    // the source leaves unstated keep the platform leading.
    lineHeight = lineHeight?.sp ?: TextUnit.Unspecified,
)

/** The resolved tokens of the current theme mode. */
public val LocalUiTokens: ProvidableCompositionLocal<UiTokens> =
    compositionLocalOf { error("PdshTheme is missing: no UiTokens in the composition") }

/** The typography styles of the current theme. */
public val LocalUiType: ProvidableCompositionLocal<UiType> =
    compositionLocalOf { error("PdshTheme is missing: no UiType in the composition") }

/**
 * Whether the active [PdshTheme] resolved its dark token table.
 *
 * The app's own appearance choice can differ from the platform theme, so bars
 * owned by a secondary window (the drawer dialog) read this instead of the OS
 * answer. It defaults to the light answer outside a host theme.
 */
public val LocalUiDarkTheme: ProvidableCompositionLocal<Boolean> =
    compositionLocalOf { false }

/**
 * Whether the platform should paint dark system-bar glyphs ("light bars").
 *
 * `isAppearanceLightStatusBars` names the *background*, not the icons: true is
 * the light chrome that needs dark glyphs. The app's effective [darkTheme]
 * decides it, so an explicit 深色/淺色 choice also reaches the status and
 * navigation bars instead of only `enableEdgeToEdge`'s system-theme answer.
 */
public fun useLightSystemBars(darkTheme: Boolean): Boolean = !darkTheme

/**
 * Applies [darkTheme]'s glyph appearance to a window's status/navigation bars.
 *
 * Both the activity window ([PdshTheme]) and the drawer's dialog window call
 * this, so neither keeps a second copy of the rule.
 */
internal fun applySystemBarAppearance(window: Window, view: View, darkTheme: Boolean) {
    WindowCompat.getInsetsController(window, view).apply {
        val light = useLightSystemBars(darkTheme)
        isAppearanceLightStatusBars = light
        isAppearanceLightNavigationBars = light
    }
}

/** The hosting activity of a Compose view, walking theme wrappers; null in previews. */
private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/**
 * Provides the PDSH tokens to the tree.
 *
 * There is deliberately no MaterialTheme wrapper: the spec's chrome is drawn
 * from the token table, and a Material colour scheme would silently introduce a
 * second source of colour for the page role.
 */
@Composable
public fun PdshTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    typePreferences: UiTypePreferences = UiTypePreferences(),
    content: @Composable () -> Unit,
) {
    val viewportWidth = LocalConfiguration.current.screenWidthDp.dp
    val tokens = remember(darkTheme, viewportWidth) { UiTokens.resolve(darkTheme, viewportWidth) }
    val type = remember(typePreferences) { UiType.fromSpec().applyPreferences(typePreferences) }
    val view = LocalView.current
    val hostActivity = view.context.findActivity()
    if (!LocalInspectionMode.current && hostActivity != null) {
        SideEffect {
            val window = hostActivity.window ?: return@SideEffect
            applySystemBarAppearance(window, view, darkTheme)
        }
    }
    androidx.compose.runtime.CompositionLocalProvider(
        LocalUiTokens provides tokens,
        LocalUiType provides type,
        LocalUiDarkTheme provides darkTheme,
        content = content,
    )
}

/** Reads the current tokens; only valid inside [PdshTheme]. */
public object PdshThemeValues {
    public val tokens: UiTokens
        @Composable @ReadOnlyComposable get() = LocalUiTokens.current

    public val type: UiType
        @Composable @ReadOnlyComposable get() = LocalUiType.current
}
