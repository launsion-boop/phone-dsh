// SPDX-License-Identifier: MIT
//
// HomeTabBar: the bottom menu of the home shell
// (`examples/probe-app/PhoneDSHProbe/HomeTabBar.swift`, `NativeShell.swift:189-246`).
//
// iOS draws four equal columns — Bot, DSH, 发现, 我的 (`HomeTabBar.swift:9-21`).
// Android gains the Bot column in wave 4, but only when the host supplies a Bot
// chat driver (`PdshNavHost.botDriver`); a host without one keeps the previous
// three-column bar (`showBot = false`), so `:app` is unchanged until a later
// lane wires the runtime. The bar belongs to the first-level pages only: it
// shows while a tab's root page is on top and leaves while a page is pushed over
// it, while the keyboard is up, and under the drawer — the same three rules as
// `NativeShell.tabPages`.
//
// The tab roots are routes ([PdshRoute.Bot], [PdshRoute.Chat],
// [PdshRoute.Discover], [PdshRoute.MeTab]) so that the stack stays a plain value:
// selecting a tab replaces the stack above the home floor with that tab's root,
// and the system back from a non-DSH tab returns to DSH (the platform's own
// convention for a bottom bar; iOS has no back gesture on a tab root to mirror).
package com.phonedsh.ui.nav

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.lib.R
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** One bottom-menu tab (`HomeTab`, `HomeTabBar.swift:9-21`), in iOS order. */
public enum class HomeTab(public val title: String) {
    /**
     * Bot: the Bot chat page. Shown only when the host supplies a
     * `BotChatDriver` (`PdshNavHost.botDriver`); [visibleTabs] is the one gate.
     */
    BOT("Bot"),

    /** 任务: the chat page, where the app opens. iOS labels it DSH and draws the DeepSeek logo. */
    TASKS("DSH"),
    DISCOVER("发现"),
    ME("我的"),
    ;

    /** The tab's root page. */
    public val root: PdshRoute
        get() = when (this) {
            BOT -> PdshRoute.Bot
            TASKS -> PdshRoute.Chat
            DISCOVER -> PdshRoute.Discover
            ME -> PdshRoute.MeTab
        }

    /** True for the one tab whose presence depends on a host-supplied driver. */
    public val requiresBotDriver: Boolean get() = this == BOT

    public companion object {
        /**
         * The tabs this bar renders. A host with no Bot driver gets exactly the
         * three tabs it had before the Bot port; the Bot root is never dropped,
         * it is only absent from the bar.
         */
        public fun visibleTabs(showBot: Boolean): List<HomeTab> =
            entries.filter { showBot || !it.requiresBotDriver }
    }
}

/** Test tags of the bottom menu. */
public object HomeTabBarTags {
    public const val BAR: String = "pdsh.home.tabbar"
    public const val TAB_PREFIX: String = "pdsh.home.tabbar."
}

/**
 * The tab whose root page is on top, or `null` when a page is pushed over it (or
 * the stack is not a tab stack at all, such as the probe face). Only [PdshRoute.Home]
 * and [PdshRoute.Chat] may sit below a tab root.
 */
public fun PdshNavState.selectedHomeTab(): HomeTab? {
    // The selected tab is the authority, not the route value: the Bot tab and
    // the DSH chat share the chat-surface route (`PdshRoute.Bot` is its value
    // alias), so two tabs would otherwise both match `current`. A route on the
    // home floor is the selected tab's root; anything pushed over it hides the bar.
    val tab = selectedTab
    if (current != tab.root) return null
    val below = stack.dropLast(1)
    val floorOnly = below.all { it == PdshRoute.Home || it == PdshRoute.Chat }
    return if (floorOnly) tab else null
}

/**
 * The bar: equal columns, an icon over a 10.5 pt medium label; the selected tab in
 * the primary ink, the others in the placeholder ink. It shares the page colour and
 * draws no top divider (`HomeTabBar.swift:1-5`), and paints the navigation-bar inset
 * itself.
 */
@Composable
public fun HomeTabBar(
    selection: HomeTab,
    onSelect: (HomeTab) -> Unit,
    modifier: Modifier = Modifier,
    /**
     * Whether the Bot column is present. The host passes
     * `botDriver != null`; the default keeps every existing host's bar
     * unchanged (`HomeTab.visibleTabs(false)`).
     */
    showBot: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(tokens.colors.page)
            .windowInsetsPadding(WindowInsets.navigationBars)
            .height(HomeMetrics.tabBarHeight)
            .testTag(HomeTabBarTags.BAR),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.Top,
    ) {
        HomeTab.visibleTabs(showBot).forEach { tab ->
            val selected = tab == selection
            val ink = if (selected) tokens.colors.textPrimary else tokens.colors.textPlaceholder
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable(role = Role.Tab) { if (!selected) onSelect(tab) }
                    .semantics(mergeDescendants = true) {
                        contentDescription = tab.title
                        this.selected = selected
                    }
                    .testTag(HomeTabBarTags.TAB_PREFIX + tab.name.lowercase())
                    .padding(top = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                // iOS gives the DSH tab a 25 pt DeepSeek logo inside the 28 pt
                // icon box (`HomeTabBar.swift:109-120`); the other tabs keep
                // their existing 23 pt share of the box.
                Box(Modifier.size(HomeMetrics.tabIcon), contentAlignment = Alignment.Center) {
                    val glyphSize = HomeMetrics.tabIcon * TAB_GLYPH_SHARE
                    when (tab) {
                        HomeTab.TASKS -> DeepSeekLogo(
                            ink = ink,
                            modifier = Modifier.size(HomeMetrics.tabIcon * DEEPSEEK_GLYPH_SHARE),
                        )
                        HomeTab.DISCOVER -> CompassGlyph(
                            selected = selected,
                            ink = ink,
                            modifier = Modifier.size(glyphSize),
                        )
                        HomeTab.ME -> PersonGlyph(
                            selected = selected,
                            ink = ink,
                            modifier = Modifier.size(glyphSize),
                        )
                        HomeTab.BOT -> {
                            // The Bot tab's mark is dsh-bot's fish glyph, not a symbol
                            // (`HomeTabBar.swift:32-76`): a stroked body/tail with a
                            // filled eye when resting, a filled body with the eye cut
                            // out when selected.
                            BotFishGlyph(
                                filled = selected,
                                ink = ink,
                                modifier = Modifier.size(glyphSize),
                            )
                        }
                    }
                }
                BasicText(
                    text = tab.title,
                    style = type.caption.copy(color = ink, fontSize = HomeMetrics.TAB_LABEL_SIZE_PT.sp, fontWeight = FontWeight.Medium),
                )
            }
        }
    }
}

/** The tab glyph's share of its icon box: 23 pt in 28 pt (`HomeTabBar.swift:108`, `HomeSpec.tabIcon`). */
private const val TAB_GLYPH_SHARE: Float = 23f / 28f

/** The 23 pt square the compass and person marks are authored in. */
private const val TAB_GLYPH_BOX: Float = 23f

/** The DSH logo's 25 pt artwork in the 28 pt icon box (`HomeTabBar.swift:109-118`). */
private const val DEEPSEEK_GLYPH_SHARE: Float = 25f / 28f

/**
 * The DSH tab's DeepSeek mark: the iOS template asset
 * `Assets.xcassets/DeepSeekLogo.imageset/DeepSeekLogo.svg` at the 25 x 25 pt
 * frame iOS gives it, tinted with the tab's selected/resting ink
 * (`HomeTabBar.swift:109-118`).
 */
@Composable
private fun DeepSeekLogo(ink: Color, modifier: Modifier) {
    Image(
        painter = painterResource(R.drawable.deepseek_logo),
        contentDescription = null,
        modifier = modifier,
        colorFilter = ColorFilter.tint(ink),
    )
}

/**
 * 发现's compass mark (`HomeTabBar.swift:29`, `safari` / `safari.fill`), drawn
 * in the tab glyph's 23 pt box. The resting tab is an open ring with a filled
 * needle around a clear hub; the selected tab is a filled disc with the needle
 * cut out and the hub filled back in.
 *
 * This is original Canvas geometry that follows the reference's proportions,
 * not an SF Symbol or a screenshot asset: SF Symbols are Apple font assets and
 * are not available to the Android shell.
 */
@Composable
private fun CompassGlyph(selected: Boolean, ink: Color, modifier: Modifier) {
    androidx.compose.foundation.Canvas(modifier) {
        val scale = size.minDimension / TAB_GLYPH_BOX
        val center = androidx.compose.ui.geometry.Offset(COMPASS_CENTER * scale, COMPASS_CENTER * scale)
        if (selected) {
            // The disc and needle share one even-odd path so the needle is a
            // real cut-out, then the hub is painted back into the clear needle.
            val disc = androidx.compose.ui.graphics.Path().apply {
                addOval(
                    androidx.compose.ui.geometry.Rect(
                        center = center,
                        radius = COMPASS_DISC_RADIUS * scale,
                    ),
                )
            }
            val cutOut = androidx.compose.ui.graphics.Path().apply {
                fillType = androidx.compose.ui.graphics.PathFillType.EvenOdd
                addPath(disc)
                addPath(compassNeedlePath(scale))
            }
            drawPath(cutOut, ink)
            drawCircle(color = ink, radius = COMPASS_HUB_RADIUS * scale, center = center)
        } else {
            drawCircle(
                color = ink,
                radius = COMPASS_RING_RADIUS * scale,
                center = center,
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = COMPASS_RING_STROKE * scale),
            )
            val needle = androidx.compose.ui.graphics.Path().apply {
                fillType = androidx.compose.ui.graphics.PathFillType.EvenOdd
                addPath(compassNeedlePath(scale))
                addOval(
                    androidx.compose.ui.geometry.Rect(
                        center = center,
                        radius = COMPASS_HUB_RADIUS * scale,
                    ),
                )
            }
            drawPath(needle, ink)
        }
    }
}

/** The compass ring and 45-degree needle proportions in the 23 pt glyph box. */
private const val COMPASS_CENTER: Float = 11.5f
private const val COMPASS_RING_RADIUS: Float = 10.55f
private const val COMPASS_RING_STROKE: Float = 1.8f
private const val COMPASS_DISC_RADIUS: Float = 11.3f
private const val COMPASS_HUB_RADIUS: Float = 1.5f
private const val COMPASS_NEEDLE_HALF_LENGTH: Float = 7.65f
private const val COMPASS_NEEDLE_HALF_WIDTH: Float = 3.05f
private const val COMPASS_NEEDLE_TIP_SHARE: Float = 0.35f
private const val COMPASS_NEEDLE_BOW_SHARE: Float = 1.3f

/**
 * The compass needle: a pointed lens from the south-west tip to the north-east
 * tip with gently bowed sides, its 23 pt box centred on [COMPASS_CENTER].
 */
private fun compassNeedlePath(scale: Float): androidx.compose.ui.graphics.Path {
    val diagonal = 0.70710677f
    fun x(along: Float, across: Float): Float = (COMPASS_CENTER + (along - across) * diagonal) * scale
    fun y(along: Float, across: Float): Float = (COMPASS_CENTER - (along + across) * diagonal) * scale
    val length = COMPASS_NEEDLE_HALF_LENGTH
    val width = COMPASS_NEEDLE_HALF_WIDTH
    val tip = COMPASS_NEEDLE_TIP_SHARE * length
    val bow = COMPASS_NEEDLE_BOW_SHARE * width
    return androidx.compose.ui.graphics.Path().apply {
        moveTo(x(-length, 0f), y(-length, 0f))
        cubicTo(
            x(-tip, bow), y(-tip, bow),
            x(tip, bow), y(tip, bow),
            x(length, 0f), y(length, 0f),
        )
        cubicTo(
            x(tip, -bow), y(tip, -bow),
            x(-tip, -bow), y(-tip, -bow),
            x(-length, 0f), y(-length, 0f),
        )
        close()
    }
}

/**
 * 我的's person mark (`HomeTabBar.swift:30`, `person` / `person.fill`), drawn in
 * the tab glyph's 23 pt box: a head over a wide, low shoulder arch. The resting
 * tab strokes both; the selected tab fills them.
 */
@Composable
private fun PersonGlyph(selected: Boolean, ink: Color, modifier: Modifier) {
    androidx.compose.foundation.Canvas(modifier) {
        val scale = size.minDimension / TAB_GLYPH_BOX
        val head = androidx.compose.ui.geometry.Offset(PERSON_CENTER_X * scale, PERSON_HEAD_Y * scale)
        if (selected) {
            drawCircle(
                color = ink,
                radius = PERSON_HEAD_FILL_RADIUS * scale,
                center = head,
            )
            drawPath(personShouldersPath(scale, filled = true), ink)
        } else {
            drawCircle(
                color = ink,
                radius = PERSON_HEAD_RADIUS * scale,
                center = head,
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = PERSON_STROKE * scale),
            )
            drawPath(
                personShouldersPath(scale, filled = false),
                ink,
                style = androidx.compose.ui.graphics.drawscope.Stroke(
                    width = PERSON_STROKE * scale,
                    cap = androidx.compose.ui.graphics.StrokeCap.Round,
                    join = androidx.compose.ui.graphics.StrokeJoin.Round,
                ),
            )
        }
    }
}

/** The person mark's vertical head/body proportions in the 23 pt glyph box. */
private const val PERSON_CENTER_X: Float = 11.5f
private const val PERSON_HEAD_Y: Float = 6.35f
private const val PERSON_HEAD_RADIUS: Float = 4.05f
private const val PERSON_HEAD_FILL_RADIUS: Float = 4.65f
private const val PERSON_STROKE: Float = 1.7f

/**
 * The person shoulders: a wide, shallow dome over short sides and a flat,
 * round-cornered bottom. The filled state is drawn a little larger than the
 * stroked centreline, matching the two reference weights.
 */
private fun personShouldersPath(
    scale: Float,
    filled: Boolean,
): androidx.compose.ui.graphics.Path {
    val halfWidth = if (filled) 9.5f else 9f
    val top = if (filled) 13.1f else 13.8f
    val side = if (filled) 18.3f else 18.6f
    val bottom = if (filled) 21.3f else 20.8f
    val corner = if (filled) 0.9f else 0.7f
    val left = PERSON_CENTER_X - halfWidth
    val right = PERSON_CENTER_X + halfWidth
    // Standard cubic control ratio for a quarter ellipse.
    val kappa = 0.5522848f
    val dome = side - top
    return androidx.compose.ui.graphics.Path().apply {
        moveTo((left + corner) * scale, bottom * scale)
        lineTo((right - corner) * scale, bottom * scale)
        quadraticBezierTo(right * scale, bottom * scale, right * scale, (bottom - corner) * scale)
        lineTo(right * scale, side * scale)
        cubicTo(
            right * scale, (side - kappa * dome) * scale,
            (right - kappa * halfWidth) * scale, top * scale,
            PERSON_CENTER_X * scale, top * scale,
        )
        cubicTo(
            (left + kappa * halfWidth) * scale, top * scale,
            left * scale, (side - kappa * dome) * scale,
            left * scale, side * scale,
        )
        lineTo(left * scale, (bottom - corner) * scale)
        quadraticBezierTo(left * scale, bottom * scale, (left + corner) * scale, bottom * scale)
        close()
    }
}

/**
 * The Bot tab's fish mark (`HomeTabBar.swift:32-76`), drawn in its 16-unit box
 * (`FISH_GLYPH_BOX`). The resting tab strokes the body and fills the eye; the
 * selected tab fills the body with the eye cut out and strokes the tail.
 */
@Composable
private fun BotFishGlyph(filled: Boolean, ink: Color, modifier: Modifier) {
    androidx.compose.foundation.Canvas(modifier) {
        val scale = size.minDimension / FISH_GLYPH_BOX
        val stroke = 1.4f * scale
        val body = fishBodyPath(scale)
        val tail = fishTailPath(scale)
        if (filled) {
            // Eye cut out: one even-odd path instead of a clear blend, so the
            // hole cannot punch through the page behind the glyph.
            val filledBody = androidx.compose.ui.graphics.Path().apply {
                fillType = androidx.compose.ui.graphics.PathFillType.EvenOdd
                addPath(body)
                addOval(
                    androidx.compose.ui.geometry.Rect(
                        center = androidx.compose.ui.geometry.Offset(5.80f * scale, 7.30f * scale),
                        radius = 0.65f * scale,
                    ),
                )
            }
            drawPath(filledBody, ink)
            drawPath(body, ink, style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke))
        } else {
            drawPath(body, ink, style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke))
            drawCircle(
                color = ink,
                radius = 0.65f * scale,
                center = androidx.compose.ui.geometry.Offset(5.80f * scale, 7.30f * scale),
            )
        }
        drawPath(tail, ink, style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke))
    }
}

private const val FISH_GLYPH_BOX: Float = 16f

private fun fishBodyPath(scale: Float): androidx.compose.ui.graphics.Path =
    androidx.compose.ui.graphics.Path().apply {
        moveTo(1.9f * scale, 8f * scale)
        cubicTo(3.3f * scale, 5.9f * scale, 5.3f * scale, 4.6f * scale, 7.6f * scale, 4.6f * scale)
        cubicTo(10f * scale, 4.6f * scale, 12f * scale, 5.9f * scale, 13.5f * scale, 8f * scale)
        cubicTo(12f * scale, 10.1f * scale, 10f * scale, 11.4f * scale, 7.6f * scale, 11.4f * scale)
        cubicTo(5.3f * scale, 11.4f * scale, 3.3f * scale, 10.1f * scale, 1.9f * scale, 8f * scale)
        close()
    }

private fun fishTailPath(scale: Float): androidx.compose.ui.graphics.Path =
    androidx.compose.ui.graphics.Path().apply {
        moveTo(13.2f * scale, 8f * scale)
        lineTo(15f * scale, 5.6f * scale)
        moveTo(13.2f * scale, 8f * scale)
        lineTo(15f * scale, 10.4f * scale)
    }
