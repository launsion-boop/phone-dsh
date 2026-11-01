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

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.theme.generated.TokenType
import com.phonedsh.ui.theme.generated.UiTokenData

/** The twelve typography tokens as ready-to-use text styles. */
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
    /** System type role: Material `titleMedium` is the declared Android mapping (±2pt tolerance). */
    public val headline: TextStyle,
    /** System type role: Material `titleSmall` is the declared Android mapping (±2pt tolerance). */
    public val subheadline: TextStyle,
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
            shimmer = UiTokenData.typeShimmer.style(),
            jsonLabel = UiTokenData.typeJsonLabel.style(),
            jsonBody = UiTokenData.typeJsonBody.style(),
            headline = UiTokenData.typeHeadline.style(),
            subheadline = UiTokenData.typeSubheadline.style(),
        )
    }
}

/** `baseSize` is emitted in `sp` so the platform scale is the only multiplier. */
internal fun TokenType.style(): TextStyle = TextStyle(
    fontSize = baseSize.sp,
    fontWeight = FontWeight(weight),
    fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
)

/** The resolved tokens of the current theme mode. */
public val LocalUiTokens: ProvidableCompositionLocal<UiTokens> =
    compositionLocalOf { error("PdshTheme is missing: no UiTokens in the composition") }

/** The typography styles of the current theme. */
public val LocalUiType: ProvidableCompositionLocal<UiType> =
    compositionLocalOf { error("PdshTheme is missing: no UiType in the composition") }

/**
 * Provides the PDSH tokens to the tree.
 *
 * There is deliberately no MaterialTheme wrapper: the spec's chrome is drawn
 * from the token table, and a Material colour scheme would silently introduce a
 * second source of colour for `background` (which the spec marks unmeasured).
 */
@Composable
public fun PdshTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val tokens = remember(darkTheme) { UiTokens.resolve(darkTheme) }
    val type = remember { UiType.fromSpec() }
    androidx.compose.runtime.CompositionLocalProvider(
        LocalUiTokens provides tokens,
        LocalUiType provides type,
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
