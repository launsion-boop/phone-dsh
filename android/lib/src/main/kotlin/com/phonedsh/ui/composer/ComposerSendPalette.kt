// Resolves the §5 fill/ink references to Android colours.
// SPDX-License-Identifier: MIT
//
// `interaction.composerSend` stores colour *references*, not literals. The
// resolved theme lives in UiTokens.colors; this projection keeps the component
// reading the group itself, so a spec reference change flows through instead of
// drifting from a hard-coded role name.
package com.phonedsh.ui.composer

import androidx.compose.ui.graphics.Color
import com.phonedsh.ui.theme.generated.TokenColor
import com.phonedsh.ui.theme.generated.TokenComposerSendInteraction

/** The four §5 roles, resolved for one appearance. */
internal data class ComposerSendPalette(
    val enabledFill: Color,
    val enabledInk: Color,
    val disabledFill: Color,
    val disabledInk: Color,
)

/** Rule 3: enabled `primaryButton`/`primaryButtonInk`, disabled `userBubble`/`iconMuted`. */
internal fun composerSendPalette(
    composer: TokenComposerSendInteraction,
    dark: Boolean,
): ComposerSendPalette = ComposerSendPalette(
    enabledFill = composer.enabledFill.composerColor(dark),
    enabledInk = composer.enabledInk.composerColor(dark),
    disabledFill = composer.disabledFill.composerColor(dark),
    disabledInk = composer.disabledInk.composerColor(dark),
)

/**
 * Resolves one literal colour token for [dark].
 *
 * The §5 group only references literal roles; a semantic or unmeasured
 * reference has no Android projection here, so it fails loudly instead of
 * inventing a colour.
 */
internal fun TokenColor.composerColor(dark: Boolean): Color {
    check(semantic == null && !unmeasured) {
        "interaction.composerSend colour '$name' has no literal Android projection"
    }
    val lightOrDark: Long? = if (dark) this.dark else light
    val argb: Long = lightOrDark
        ?: error("interaction.composerSend colour '$name' is missing its ${if (dark) "dark" else "light"} value")
    val alpha: Float = if (dark) darkAlpha else lightAlpha
    return Color(argb).copy(alpha = alpha)
}
