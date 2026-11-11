// Disclosure motion contract from spec/ui/v1/interaction.md §7.
// SPDX-License-Identifier: MIT
//
// This file deliberately has no Compose runtime dependency: the shared golden
// test drives the same resolver the disclosure composables use. Every duration
// and curve comes from the generated `interaction.disclosure` table; the only
// derived value is the reduced-motion snap (rule 5).
package com.phonedsh.ui.disclosure

import com.phonedsh.ui.theme.generated.TokenMotion
import com.phonedsh.ui.theme.generated.TokenReducedMotion
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * The three motions named by `interaction.md` §7.
 *
 * [id] is the shared golden row id (`spec/ui/v1/golden/disclosure-motion.golden.json`).
 */
public enum class DisclosureKind(public val id: String) {
    /** Rule 1: a message/tool body expands as one unit with `motion.disclosure`. */
    BODY("body"),

    /** Rule 2: a drawer folder group inserts/removes with `motion.folderCollapse`. */
    FOLDER("folder"),

    /** Rule 3: a disclosure chevron rotates with `motion.chevron`. */
    CHEVRON("chevron"),
}

/**
 * One resolved disclosure animation.
 *
 * [durationMs] is the effective duration. It is zero only when [snap] is true,
 * which is the contract's `reducedMotion: snap` value (rule 5), not an invented
 * timing. [motion] and [curve] always stay the token's own names so callers and
 * tests can still identify what would have run.
 */
public data class DisclosureSpec(
    public val kind: DisclosureKind,
    public val motion: String,
    public val durationMs: Int,
    public val curve: String,
    public val snap: Boolean,
)

/** Pure resolver for `interaction.md` §7 rules 1–3 and 5. */
public object DisclosureMotion {
    /** A snap has no elapsed time; this is the meaning of `reducedMotion: snap`, not a motion token. */
    private const val SNAP_DURATION_MS: Int = 0

    /**
     * Resolves the contract motion for [kind].
     *
     * @param reducedMotion true when the platform's animator duration scale is
     *   zero (rule 5). Every motion then snaps to its end state; the token's
     *   name and curve are retained on the result.
     */
    public fun specFor(kind: DisclosureKind, reducedMotion: Boolean): DisclosureSpec {
        val token: TokenMotion = when (kind) {
            DisclosureKind.BODY -> UiTokenData.disclosure.bodyMotion
            DisclosureKind.FOLDER -> UiTokenData.disclosure.folderMotion
            DisclosureKind.CHEVRON -> UiTokenData.disclosure.chevronMotion
        }
        val snap = reducedMotion && UiTokenData.disclosure.reducedMotion == TokenReducedMotion.SNAP
        return DisclosureSpec(
            kind = kind,
            motion = token.name,
            durationMs = if (snap) SNAP_DURATION_MS else token.durationMs,
            curve = token.curve,
            snap = snap,
        )
    }
}
