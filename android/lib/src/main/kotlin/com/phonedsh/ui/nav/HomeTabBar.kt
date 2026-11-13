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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** One bottom-menu tab (`HomeTab`, `HomeTabBar.swift:9-21`), in iOS order. */
public enum class HomeTab(public val title: String, internal val icon: PdshIcon?) {
    /**
     * Bot: the Bot chat page. Shown only when the host supplies a
     * `BotChatDriver` (`PdshNavHost.botDriver`); [visibleTabs] is the one gate.
     */
    BOT("Bot", null),

    /** 任务: the chat page, where the app opens. iOS labels it DSH. */
    TASKS("DSH", PdshIcon.CHAT_BUBBLE),
    DISCOVER("发现", PdshIcon.GLOBE),
    ME("我的", PdshIcon.PEOPLE),
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
                    .padding(top = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(1.dp),
            ) {
                // A ≈23 pt glyph in the 28 pt icon box (`HomeTabBar.swift:106-118`).
                Box(Modifier.size(HomeMetrics.tabIcon), contentAlignment = Alignment.Center) {
                    val icon = tab.icon
                    if (icon != null) {
                        PdshIconView(
                            icon = icon,
                            size = HomeMetrics.tabIcon * TAB_GLYPH_SHARE,
                            tint = ink,
                            contentDescription = null,
                        )
                    } else {
                        // The Bot tab's mark is dsh-bot's fish glyph, not a symbol
                        // (`HomeTabBar.swift:32-76`): a stroked body/tail with a
                        // filled eye when resting, a filled body with the eye cut
                        // out when selected.
                        BotFishGlyph(
                            filled = selected,
                            ink = ink,
                            modifier = Modifier.size(HomeMetrics.tabIcon * TAB_GLYPH_SHARE),
                        )
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

/**
 * The Bot tab's fish mark (`HomeTabBar.swift:32-76`), drawn in its 16-unit box
 * (`FISH_GLYPH_BOX`). The resting tab strokes the body and fills the eye; the
 * selected tab fills the body with the eye cut out and strokes the tail.
 */
@Composable
private fun BotFishGlyph(filled: Boolean, ink: androidx.compose.ui.graphics.Color, modifier: Modifier) {
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
