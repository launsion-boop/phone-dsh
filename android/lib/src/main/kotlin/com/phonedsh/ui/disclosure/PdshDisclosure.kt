// Disclosure UI from spec/ui/v1/interaction.md §7.
// SPDX-License-Identifier: MIT
//
// The header is outside the animated body (rule 6): expanding or collapsing
// below it never moves the row the user tapped. The body is one unit — one
// height transition and one opacity transition — never a per-row stagger
// (rule 4). Chevrons rotate in place (rule 3) and keep their layout box.
package com.phonedsh.ui.disclosure

import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.UiMotion

/**
 * What the caller needs to keep the tapped row in place while a body changes
 * height (rule 6): the row's stable [key] and its bounds in root coordinates at
 * the moment of the tap. A `LazyList`/scroll owner can use [headerBoundsInRoot]
 * to compensate a scroll delta; the disclosure itself never scrolls.
 */
@Immutable
public data class DisclosureAnchor(
    /** Caller-supplied row identity; `null` when the caller does not need one. */
    public val key: Any?,
    /** The header's bounds in root coordinates at tap time; the body is not included. */
    public val headerBoundsInRoot: Rect,
) {
    /** The header's top edge in root pixels; the value a scroll anchor keeps fixed. */
    public val headerTopPx: Float get() = headerBoundsInRoot.top
}

/** Stable test tags derived from one disclosure's [tag]. */
public object PdshDisclosureTags {
    /** The clickable header (the row that must not jump). */
    public fun header(tag: String): String = "$tag.header"

    /** The animated body container. */
    public fun body(tag: String): String = "$tag.body"

    /** A [PdshChevron]’s mark. */
    public fun chevron(tag: String): String = "$tag.chevron"
}

/**
 * A header whose body expands and collapses as one unit.
 *
 * Implements `interaction.md` §7 rules 1, 4, 5 and 6: `motion.disclosure`
 * height plus opacity, no per-row stagger, a platform-reduced-motion snap, and a
 * header outside the animated region. One tap invokes [onToggle] exactly once.
 *
 * @param expanded whether [body] is shown.
 * @param onToggle the single toggle callback. It receives the header anchor
 *   captured at tap time so a scroll owner can keep that row fixed.
 * @param modifier the root column modifier.
 * @param tag when non-null, [PdshDisclosureTags] tags are attached for tests and
 *   host diagnostics.
 * @param anchorKey a stable row identity reported in [DisclosureAnchor.key].
 * @param header the always-visible row content; it is not animated.
 * @param body the collapsible content; the whole lambda is one animation unit.
 */
@Composable
public fun PdshDisclosure(
    expanded: Boolean,
    onToggle: (DisclosureAnchor) -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    anchorKey: Any? = null,
    header: @Composable () -> Unit,
    body: @Composable () -> Unit,
) {
    DisclosureLayout(
        kind = DisclosureKind.BODY,
        expanded = expanded,
        onToggle = onToggle,
        modifier = modifier,
        tag = tag,
        anchorKey = anchorKey,
        onLongPress = null,
        interactionSource = null,
        header = header,
        body = body,
    )
}

/**
 * The drawer folder-group variant of [PdshDisclosure].
 *
 * It is the same one-unit height/opacity body and fixed header, but rule 2’s
 * `motion.folderCollapse` drives it. The optional [onLongPress] lets the drawer
 * keep its folder context menu on the same row without adding a second click
 * target: one tap still toggles once.
 *
 * @param expanded whether the folder’s sessions are shown.
 * @param onToggle the single toggle callback, with the same [DisclosureAnchor]
 *   contract as [PdshDisclosure].
 * @param modifier the root column modifier.
 * @param tag when non-null, [PdshDisclosureTags] tags are attached.
 * @param anchorKey a stable folder identity reported in [DisclosureAnchor.key].
 * @param onLongPress an optional folder context-menu gesture; it never toggles.
 * @param interactionSource an optional source for the header's one clickable.
 *   Pass the same source to `rowPressed`/`pillPressed` so a page can paint the
 *   §6 press feedback without installing a second pointer observer; `null`
 *   keeps the component's own source.
 * @param header the folder row, including its [PdshChevron].
 * @param body the folder’s sessions/empty copy, animated as one unit.
 */
@Composable
public fun PdshFolderGroup(
    expanded: Boolean,
    onToggle: (DisclosureAnchor) -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    anchorKey: Any? = null,
    onLongPress: (() -> Unit)? = null,
    interactionSource: MutableInteractionSource? = null,
    header: @Composable () -> Unit,
    body: @Composable () -> Unit,
) {
    DisclosureLayout(
        kind = DisclosureKind.FOLDER,
        expanded = expanded,
        onToggle = onToggle,
        modifier = modifier,
        tag = tag,
        anchorKey = anchorKey,
        onLongPress = onLongPress,
        interactionSource = interactionSource,
        header = header,
        body = body,
    )
}

/**
 * A chevron that rotates 0° → 90° with `motion.chevron` (rule 3).
 *
 * The mark keeps one fixed layout box for every rotation; only its drawing
 * transform changes, so a row’s height is identical before, during and after the
 * toggle. The mark itself is not clickable: the enclosing header owns the one
 * toggle per tap.
 *
 * @param expanded target rotation; 90° when true, 0° when false.
 * @param modifier the caller’s modifier; it is applied before the fixed size.
 * @param size the mark’s fixed layout size; geometry is caller-owned, not part
 *   of `interaction.disclosure`.
 * @param tint the mark’s ink.
 * @param tag an optional stable test tag.
 * @param contentDescription optional accessibility label; the header normally
 *   supplies the row’s label.
 * @param onRotationChanged optional observer for the animated degrees; useful
 *   for hosts that synchronize another mark. It is called after composition
 *   with the value currently drawn.
 */
@Composable
public fun PdshChevron(
    expanded: Boolean,
    modifier: Modifier = Modifier,
    size: Dp = 12.dp,
    tint: Color = LocalUiTokens.current.colors.textPlaceholder,
    tag: String? = null,
    contentDescription: String? = null,
    onRotationChanged: ((Float) -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val reducedMotion = systemReducedMotion(expanded)
    val spec = DisclosureMotion.specFor(DisclosureKind.CHEVRON, reducedMotion)
    val target = if (expanded) 90f else 0f
    val animated by animateFloatAsState(
        targetValue = target,
        animationSpec = finiteSpec<Float>(spec, tokens.motion),
        label = "pdsh-chevron",
    )
    // Rule 5: an explicit snap branch guarantees the end value is what is drawn,
    // with no intermediate frame even before the animation clock advances.
    val rotation = if (spec.snap) target else animated
    if (onRotationChanged != null) {
        SideEffect { onRotationChanged(rotation) }
    }
    PdshIconView(
        icon = PdshIcon.CHEVRON_RIGHT,
        size = size,
        tint = tint,
        contentDescription = contentDescription,
        modifier = modifier
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .rotate(rotation),
    )
}

/**
 * The one implementation behind [PdshDisclosure] and [PdshFolderGroup].
 *
 * The caller’s modifier is not forced to fill width: a disclosure can sit in a
 * drawer, a card or a list row. The header and body themselves fill the width
 * their parent gives them.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DisclosureLayout(
    kind: DisclosureKind,
    expanded: Boolean,
    onToggle: (DisclosureAnchor) -> Unit,
    modifier: Modifier,
    tag: String?,
    anchorKey: Any?,
    onLongPress: (() -> Unit)?,
    interactionSource: MutableInteractionSource?,
    header: @Composable () -> Unit,
    body: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val spec = DisclosureMotion.specFor(kind, systemReducedMotion(expanded))
    val sizeSpec = finiteSpec<IntSize>(spec, tokens.motion)
    val fadeSpec = finiteSpec<Float>(spec, tokens.motion)
    var headerBounds by remember { mutableStateOf(Rect.Zero) }
    val onTap = { onToggle(DisclosureAnchor(anchorKey, headerBounds)) }
    val headerGesture = when {
        onLongPress != null && interactionSource != null -> Modifier.combinedClickable(
            interactionSource = interactionSource,
            indication = LocalIndication.current,
            role = Role.Button,
            onClickLabel = null,
            onLongClickLabel = null,
            onLongClick = onLongPress,
            onClick = onTap,
        )
        onLongPress != null -> Modifier.combinedClickable(
            role = Role.Button,
            onClickLabel = null,
            onLongClickLabel = null,
            onLongClick = onLongPress,
            onClick = onTap,
        )
        interactionSource != null -> Modifier.clickable(
            interactionSource = interactionSource,
            indication = LocalIndication.current,
            role = Role.Button,
            onClick = onTap,
        )
        else -> Modifier.clickable(role = Role.Button, onClick = onTap)
    }

    Column(modifier = modifier) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (tag != null) Modifier.testTag(PdshDisclosureTags.header(tag)) else Modifier)
                .onGloballyPositioned { headerBounds = it.boundsInRoot() }
                .then(headerGesture),
        ) {
            header()
        }
        if (spec.snap) {
            // Rule 5: the platform disabled animations; compose the end state
            // directly instead of running a zero-duration transition.
            if (expanded) {
                Column(modifier = Modifier.fillMaxWidth().bodyTag(tag)) { body() }
            }
        } else {
            AnimatedVisibility(
                visible = expanded,
                enter = expandVertically(
                    animationSpec = sizeSpec,
                    expandFrom = Alignment.Top,
                ) + fadeIn(animationSpec = fadeSpec),
                exit = shrinkVertically(
                    animationSpec = sizeSpec,
                    shrinkTowards = Alignment.Top,
                ) + fadeOut(animationSpec = fadeSpec),
            ) {
                Column(modifier = Modifier.fillMaxWidth().bodyTag(tag)) { body() }
            }
        }
    }
}

/**
 * Rule 5: the platform animator duration scale is the only reduced-motion input.
 *
 * [key] is the state whose change re-reads the setting; animation frames alone
 * do not. A system setting change is picked up on the next toggle/recomposition
 * rather than by querying the resolver on every animation frame.
 */
@Composable
private fun systemReducedMotion(key: Any?): Boolean {
    val context = LocalContext.current
    return remember(key, context) {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }
}

/** One animation spec for every property of a motion, or the contract’s snap. */
private fun <T> finiteSpec(spec: DisclosureSpec, motion: UiMotion): FiniteAnimationSpec<T> =
    if (spec.snap) {
        snap()
    } else {
        tween(durationMillis = spec.durationMs, easing = motion.easing(spec.curve))
    }

/** Attaches the body tag only when the caller asked for stable test tags. */
private fun Modifier.bodyTag(tag: String?): Modifier =
    if (tag != null) testTag(PdshDisclosureTags.body(tag)) else this
