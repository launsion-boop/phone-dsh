// The host-wide sheet back layer, spec/ui/v1/interaction.md §2 rule 9 / §4 rule 5.
// SPDX-License-Identifier: MIT
//
// `SheetBackHost` is per *host*, not per sheet: the generated back order puts one
// `sheet` layer in front of `drawer`/`stack`/`root`, so a back gesture must reach
// the top-most mounted sheet even when the sheet is owned by a page rather than by
// the router. `PdshNavHost` therefore provides the host's shared instance here and
// `PdshSheet` falls back to it when its caller passes no explicit `backHost`.
package com.phonedsh.ui.sheet

import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * The host's one [SheetBackHost], or `null` outside a host that keeps one.
 *
 * `PdshSheet` resolves its back layer as
 * `backHost ?: LocalSheetBackHost.current ?: remember { SheetBackHost() }`:
 *
 *  * an explicit `backHost` still wins, so an in-page sheet that wants a private
 *    chain (e.g. a sheet stack inside one page) keeps it;
 *  * with a provider, every page-owned sheet registers on the host's shared
 *    chain, so the host's `sheet` back layer can see it and
 *    [SheetBackHost.dispatch] closes exactly one sheet layer at a time;
 *  * without a provider (a page previewed on its own, a screenshot harness) the
 *    sheet keeps a local chain and system back still closes it.
 *
 * The value is a plain object the host owns; the local only hands it down. It is
 * intentionally not a `compositionLocalOf`: the instance is stable for the life
 * of the host, and changing it would strand registered entries.
 */
public val LocalSheetBackHost: ProvidableCompositionLocal<SheetBackHost?> =
    staticCompositionLocalOf { null }
