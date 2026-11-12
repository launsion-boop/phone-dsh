// Sheet detent mapping, spec/ui/v1/interaction.md §2 rules 2-3.
// SPDX-License-Identifier: MIT
//
// Pure JVM logic: no Compose runtime and no hand-written detent value. The table
// lives in `tokens.json#interaction.sheet` and is read only through the generated
// `UiTokenData.sheet` accessors.
package com.phonedsh.ui.sheet

import com.phonedsh.ui.theme.generated.TokenDetent
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * Maps a modal bottom sheet page id to the frozen detent table in
 * `tokens.json#interaction.sheet` (`interaction.md` §2 rules 2-3).
 *
 * The 20 explicit page ids come from `pageDetents`; an unlisted sheet uses
 * `defaultDetents`, which rule 2 defines as the system single large detent. No
 * page id or detent set is repeated in this file.
 */
public object SheetDetents {
    /**
     * Rule 2: the detent set for [pageId], or the contract default when the page
     * is not one of the explicit sites. A `null` id means "unlisted".
     */
    public fun forPage(pageId: String?): TokenDetentSetId =
        UiTokenData.sheet.pageDetents
            .firstOrNull { pageId != null && it.id == pageId }
            ?.detents
            ?: UiTokenData.sheet.defaultDetents

    /**
     * The platform anchors a set names, in ascending height order.
     *
     * `default` is the contract's system single large sheet (rule 2), so it
     * resolves to [TokenDetent.LARGE] without inventing a second value. A set
     * that names `medium+large` exposes both anchors; `medium` alone exposes
     * only the platform partial anchor.
     */
    public fun detents(setId: TokenDetentSetId): List<TokenDetent> =
        when (detentGroup(setId)) {
            TokenDetent.DEFAULT, TokenDetent.LARGE -> listOf(TokenDetent.LARGE)
            TokenDetent.MEDIUM -> listOf(TokenDetent.MEDIUM)
            TokenDetent.MEDIUM_LARGE -> listOf(TokenDetent.MEDIUM, TokenDetent.LARGE)
        }

    /**
     * Rule 3: only a set with the platform partial-expand anchor stops there.
     * The partial height belongs to the platform sheet; this file never writes
     * the `mediumFraction` value.
     */
    public fun skipPartiallyExpanded(setId: TokenDetentSetId): Boolean =
        TokenDetent.MEDIUM !in detents(setId)

    /** The raw `detentSets` row, used so the table stays the one source. */
    internal fun detentGroup(setId: TokenDetentSetId): TokenDetent =
        UiTokenData.sheet.detentSets.firstOrNull { it.id == setId }?.detents
            ?: error("interaction.sheet.detentSets is missing '$setId'")
}
