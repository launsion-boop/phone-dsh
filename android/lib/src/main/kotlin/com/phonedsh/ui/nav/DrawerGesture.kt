// Pure drawer gesture rules from spec/ui/v1/README.md §3.2.
// SPDX-License-Identifier: MIT
//
// This file deliberately has no Compose runtime dependency: JVM tests drive the
// same state machine as the drawer. Every number comes from the generated
// `interaction.drawer` table; no value is repeated here.
package com.phonedsh.ui.nav

import com.phonedsh.ui.theme.generated.UiTokenData
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** What a released drag does: close with `closeMotion`, or settle back to 0. */
public enum class DrawerRelease {
    Close,
    Settle,
}

public object DrawerGesture {
    /**
     * Rule 3 axis lock plus rule 2's left-only follow.
     *
     * A vertical-dominant move keeps the previous offset; a horizontal-dominant
     * move follows `min(0, dx)` with no lower bound.
     */
    public fun followOffset(dx: Float, dy: Float, previous: Float): Float =
        if (abs(dx) > abs(dy)) min(0f, dx) else previous

    /** Rule 3: the Euclidean distance that starts a drag, in dp. */
    public fun hasStarted(distance: Float): Boolean =
        distance >= UiTokenData.drawer.dragMinimumDistancePt

    /** Rule 5: 1 when open, falling to 0 at the closed width. */
    public fun progress(offset: Float): Float =
        max(0f, 1f + offset / UiTokenData.drawer.width.value)

    /** Rule 5: black scrim opacity follows the panel progress. */
    public fun scrimAlpha(offset: Float): Float =
        UiTokenData.drawer.scrimMaxOpacity * progress(offset)

    /**
     * Rule 6: close when the raw release dx, or its velocity projection, is
     * strictly past the width-fraction threshold. Velocity is dp/s.
     */
    public fun release(dx: Float, velocity: Float): DrawerRelease {
        val threshold = UiTokenData.drawer.closeThresholdFraction * UiTokenData.drawer.width.value
        val projected = dx + velocity * UiTokenData.drawer.velocityProjectionSeconds
        return if (dx < -threshold || projected < -threshold) DrawerRelease.Close else DrawerRelease.Settle
    }
}
