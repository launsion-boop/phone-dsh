// SPDX-License-Identifier: MIT
//
// HomeTabBar: the bottom menu of the home shell
// (`examples/probe-app/PhoneDSHProbe/HomeTabBar.swift`, `NativeShell.swift:189-246`).
//
// iOS draws four equal columns — Bot, DSH, 发现, 我的. This app has no Bot runtime
// (PhoneDSHBot is an iOS module; `spec/ui/v1/pages/bot-*.md` describe iOS-only
// surfaces), so the Android bar has the other three. The bar belongs to the
// first-level pages only: it shows while a tab's root page is on top and leaves
// while a page is pushed over it, while the keyboard is up, and under the drawer —
// the same three rules as `NativeShell.tabPages`.
//
// The tab roots are routes ([PdshRoute.Chat], [PdshRoute.Discover], [PdshRoute.MeTab])
// so that the stack stays a plain value: selecting a tab replaces the stack above
// the home floor with that tab's root, and the system back from 发现 or 我的 returns
// to DSH (the platform's own convention for a bottom bar; iOS has no back gesture
// on a tab root to mirror).
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

/** One bottom-menu tab (`HomeTab`, `HomeTabBar.swift:9`), minus the iOS-only Bot. */
public enum class HomeTab(public val title: String, internal val icon: PdshIcon) {
    /** 任务: the chat page, where the app opens. iOS labels it DSH. */
    TASKS("DSH", PdshIcon.CHAT_BUBBLE),
    DISCOVER("发现", PdshIcon.GLOBE),
    ME("我的", PdshIcon.PEOPLE),
    ;

    /** The tab's root page. */
    public val root: PdshRoute
        get() = when (this) {
            TASKS -> PdshRoute.Chat
            DISCOVER -> PdshRoute.Discover
            ME -> PdshRoute.MeTab
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
    val tab = HomeTab.entries.firstOrNull { it.root == current } ?: return null
    val below = stack.dropLast(1)
    val floorOnly = below.all { it == PdshRoute.Home || it == PdshRoute.Chat }
    return if (floorOnly) tab else null
}

/**
 * The stack after picking [tab]: the home floor (the leading [PdshRoute.Home] /
 * [PdshRoute.Chat] routes), with [PdshRoute.Chat] as its top, then the tab's root
 * unless it is DSH itself.
 */
public fun PdshNavState.selectHomeTab(tab: HomeTab): PdshNavState {
    val floor = stack.takeWhile { it == PdshRoute.Home || it == PdshRoute.Chat }
    val chatFloor = floor.indexOfFirst { it == PdshRoute.Chat }
        .let { if (it >= 0) floor.take(it + 1) else floor + PdshRoute.Chat }
    return PdshNavState(if (tab == HomeTab.TASKS) chatFloor else chatFloor + tab.root)
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
        HomeTab.entries.forEach { tab ->
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
                    PdshIconView(icon = tab.icon, size = HomeMetrics.tabIcon * TAB_GLYPH_SHARE, tint = ink, contentDescription = null)
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
