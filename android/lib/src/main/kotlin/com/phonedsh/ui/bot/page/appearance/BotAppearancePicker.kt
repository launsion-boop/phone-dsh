// The shared Bot appearance editor: four hairstyle stills and fifteen colour
// swatches, emitting the frozen `BotAppearanceIntent` vocabulary.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotAppearancePicker.swift`
// and `spec/ui/v1/pages/bot-info.md` §外观. The info page hides the picker's own
// preview because its header already draws the 80 pt avatar; the add-Bot dialog
// also hides it because it keeps a 104 pt draft preview above the form
// (`BotAppearancePicker.swift:25-30`, `BotDrawer.swift:699`).
package com.phonedsh.ui.bot.page.appearance

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.state.BotAppearanceIntent
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/**
 * The four hairstyles and fifteen colours of one Bot's appearance.
 *
 * Selection is rendered from [appearance] and never stored here; writing is the
 * caller's decision (the info page saves per tap, the add dialog keeps a draft
 * until 创建). Every tap reports one [BotAppearanceIntent].
 *
 * @param appearance the current local appearance.
 * @param onIntent one selection; the caller applies and persists it.
 * @param fish the host's fish renderer, used for the optional preview and for
 *   the four still thumbnails.
 * @param identifierPrefix the frozen id prefix (`bot.info.appearance` on the
 *   info page, `bot.add.appearance` in the add dialog).
 * @param isMainBot draws the crown on the preview/thumbnails.
 * @param showsPreview draws the picker's own preview; the info page and the
 *   add dialog both pass `false` because they already have an avatar.
 */
@Composable
public fun BotAppearancePicker(
    appearance: BotFishAppearance,
    onIntent: (BotAppearanceIntent) -> Unit,
    fish: BotFishSlot,
    modifier: Modifier = Modifier,
    identifierPrefix: String = BotAppearanceTags.INFO_PREFIX,
    isMainBot: Boolean = false,
    showsPreview: Boolean = true,
    previewSize: Dp = BotAppearanceMetrics.PREVIEW_SIZE,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val contentInset = tokens.geometry.pageOuterMarginH

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = BotAppearanceMetrics.PICKER_VERTICAL_PADDING)
            .semantics(mergeDescendants = false) {},
        verticalArrangement = Arrangement.spacedBy(BotAppearanceMetrics.GROUP_GAP),
    ) {
        if (showsPreview) {
            val previewLabel = BotAppearanceCopy.previewLabel(
                color = appearance.color.displayName,
                hairstyle = appearance.hairstyle.displayName,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = previewLabel },
                contentAlignment = Alignment.Center,
            ) {
                fish(
                    BotFishLifecycle.IDLE,
                    appearance,
                    isMainBot,
                    previewSize,
                    true,
                    Modifier,
                )
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = contentInset),
            verticalArrangement = Arrangement.spacedBy(BotAppearanceMetrics.LABEL_GAP),
        ) {
            BasicText(
                text = BotAppearanceCopy.HAIRSTYLE,
                style = type.secondary.copy(
                    color = tokens.colors.textSecondary,
                    fontSize = BotAppearanceMetrics.LABEL_SIZE,
                ),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(BotAppearanceMetrics.HAIRSTYLE_GAP)) {
                BotFishHairstyle.entries.forEach { hairstyle ->
                    BotHairstyleButton(
                        appearance = appearance,
                        hairstyle = hairstyle,
                        isMainBot = isMainBot,
                        fish = fish,
                        tag = BotAppearanceTags.hair(identifierPrefix, hairstyle.wire),
                        onClick = { onIntent(BotAppearanceIntent.SelectHairstyle(hairstyle)) },
                    )
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(BotAppearanceMetrics.LABEL_GAP)) {
            BasicText(
                text = BotAppearanceCopy.COLOR,
                style = type.secondary.copy(
                    color = tokens.colors.textSecondary,
                    fontSize = BotAppearanceMetrics.LABEL_SIZE,
                ),
                modifier = Modifier.padding(horizontal = contentInset),
            )
            BotColorStrip(
                appearance = appearance,
                identifierPrefix = identifierPrefix,
                onSelect = { onIntent(BotAppearanceIntent.SelectColor(it)) },
            )
        }
    }
}

@Composable
private fun BotHairstyleButton(
    appearance: BotFishAppearance,
    hairstyle: BotFishHairstyle,
    isMainBot: Boolean,
    fish: BotFishSlot,
    tag: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val selected = appearance.hairstyle == hairstyle
    val interaction = remember(hairstyle) { MutableInteractionSource() }
    // The thumbnail keeps the current colour and drops the automatic flag, the
    // same per-field write the info page performs (`BotAppearancePicker.swift:94-99`).
    val thumbnail = appearance.copy(hairstyle = hairstyle, autoHairstyle = false)
    Box(
        modifier = Modifier
            .size(BotAppearanceMetrics.HAIRSTYLE_SLOT)
            .background(
                if (selected) tokens.colors.userBubble else Color.Transparent,
                CircleShape,
            )
            .then(
                if (selected) {
                    Modifier.border(
                        BotAppearanceMetrics.HAIRSTYLE_SELECTED_RING,
                        tokens.colors.primaryButton,
                        CircleShape,
                    )
                } else {
                    Modifier
                },
            )
            .selectable(
                selected = selected,
                interactionSource = interaction,
                indication = null,
                role = Role.RadioButton,
                onClick = onClick,
            )
            .semantics { contentDescription = hairstyle.displayName }
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        fish(
            BotFishLifecycle.IDLE,
            thumbnail,
            isMainBot,
            BotAppearanceMetrics.HAIRSTYLE_FISH,
            true,
            Modifier,
        )
    }
}

@Composable
private fun BotColorStrip(
    appearance: BotFishAppearance,
    identifierPrefix: String,
    onSelect: (BotFishColor) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val colors = BotFishColor.entries
    val selectedIndex = colors.indexOf(appearance.color).coerceAtLeast(0)
    val listState = rememberLazyListState()

    // `BotAppearancePicker.swift:80-84`: the selected swatch is visible as soon
    // as the page opens, without an animation.
    LaunchedEffect(appearance.color) {
        listState.scrollToItem(selectedIndex)
    }

    LazyRow(
        state = listState,
        modifier = Modifier
            .fillMaxWidth()
            // The trailing fade hints that the row continues; the mask spans the
            // row so the part-visible next swatch reaches the card edge
            // (`BotAppearancePicker.swift:63-79`).
            .drawWithContent {
                drawContent()
                if (size.width <= 0f) return@drawWithContent
                val leading = BotAppearanceMetrics.FADE_LEADING.toPx()
                val trailing = BotAppearanceMetrics.FADE_TRAILING.toPx()
                drawRect(
                    brush = Brush.horizontalGradient(
                        0f to Color.Transparent,
                        (leading / size.width).coerceIn(0f, 1f) to Color.Black,
                        (1f - trailing / size.width).coerceIn(0f, 1f) to Color.Black,
                        1f to Color.Transparent,
                    ),
                    blendMode = BlendMode.DstIn,
                )
            },
        contentPadding = PaddingValues(
            horizontal = tokens.geometry.pageOuterMarginH,
            vertical = BotAppearanceMetrics.COLOR_ROW_VERTICAL_PADDING,
        ),
        horizontalArrangement = Arrangement.spacedBy(BotAppearanceMetrics.COLOR_GAP),
    ) {
        items(colors.size, key = { colors[it].wire }) { index ->
            val color = colors[index]
            BotColorButton(
                color = color,
                selected = appearance.color == color,
                tag = BotAppearanceTags.color(identifierPrefix, color.wire),
                onClick = { onSelect(color) },
            )
        }
    }
}

@Composable
private fun BotColorButton(
    color: BotFishColor,
    selected: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val interaction = remember(color) { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .size(BotAppearanceMetrics.COLOR_SLOT)
            .selectable(
                selected = selected,
                interactionSource = interaction,
                indication = null,
                role = Role.RadioButton,
                onClick = onClick,
            )
            .semantics { contentDescription = color.displayName }
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        // The selected ring is drawn outside the 24 pt swatch (`:130-143`).
        Box(
            Modifier
                .size(BotAppearanceMetrics.COLOR_RING)
                .then(
                    if (selected) {
                        Modifier.border(
                            BotAppearanceMetrics.HAIRSTYLE_SELECTED_RING,
                            tokens.colors.primaryButton,
                            CircleShape,
                        )
                    } else {
                        Modifier
                    },
                ),
        )
        Box(
            Modifier
                .size(BotAppearanceMetrics.COLOR_SWATCH)
                .background(swatchColor(color), CircleShape)
                .border(
                    width = if (selected) {
                        BotAppearanceMetrics.COLOR_SELECTED_HAIRLINE
                    } else {
                        BotAppearanceMetrics.COLOR_HAIRLINE
                    },
                    color = if (selected) {
                        tokens.colors.borderList
                    } else {
                        // Unselected swatches get an adaptive hairline: the black
                        // swatch almost disappears on a dark page without it
                        // (`BotAppearancePicker.swift:131-136`).
                        tokens.colors.textPrimary.copy(alpha = UNSELECTED_HAIRLINE_ALPHA)
                    },
                    shape = CircleShape,
                ),
        )
    }
}

/** `BotAppearancePicker.swatch(_:)`; a malformed hex falls back to grey (`:152-158`). */
internal fun swatchColor(color: BotFishColor): Color {
    val hex = color.hex.removePrefix("#")
    val value = hex.toLongOrNull(16) ?: return Color.Gray
    return Color(0xFF000000L or value)
}

/** `Color.primary.opacity(0.3)` (`BotAppearancePicker.swift:135`). */
private const val UNSELECTED_HAIRLINE_ALPHA: Float = 0.3f
