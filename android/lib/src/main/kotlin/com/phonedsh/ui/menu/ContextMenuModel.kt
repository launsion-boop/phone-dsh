// Long-press context-menu rules from spec/ui/v1/interaction.md §3.
// SPDX-License-Identifier: MIT
//
// This file deliberately has no Compose runtime dependency: JVM tests drive the
// same filtering and label resolution as the renderer. Every label, role, kind,
// condition and divider flag comes from the generated
// `interaction.contextMenu` table; nothing is repeated here.
package com.phonedsh.ui.menu

import com.phonedsh.ui.theme.generated.TokenContextMenuKind
import com.phonedsh.ui.theme.generated.TokenContextMenuItem
import com.phonedsh.ui.theme.generated.TokenContextMenuRole
import com.phonedsh.ui.theme.generated.TokenContextMenuSurface
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * Row state for one `interaction.contextMenu` surface.
 *
 * [predicates] is the row-state predicate set: a missing condition is false
 * except [TokenContextMenuWhen.ALWAYS], which defaults to true so callers do not
 * have to repeat an unconditional item. Passing an explicit `false` still hides
 * it because rule 2 evaluates `when` rather than special-casing the spelling.
 *
 * [botHidden] is the table's one state-dependent label: when true, an item's
 * `altLabel` replaces its `label` (the `botRow` hidden-state label, rule 5).
 */
public data class ContextMenuRowState(
    public val predicates: Map<TokenContextMenuWhen, Boolean> = emptyMap(),
    public val botHidden: Boolean = false,
) {
    /** Rule 2: an item is shown only when its `when` evaluates true. */
    public fun shows(condition: TokenContextMenuWhen): Boolean =
        predicates[condition] ?: (condition == TokenContextMenuWhen.ALWAYS)

    public companion object {
        /** Builds a state without naming every enum entry; absent conditions are false. */
        public fun of(
            vararg predicates: Pair<TokenContextMenuWhen, Boolean>,
            botHidden: Boolean = false,
        ): ContextMenuRowState = ContextMenuRowState(predicates.toMap(), botHidden)

        /** The unconditional row: only `always` items are visible. */
        public val unconditional: ContextMenuRowState = ContextMenuRowState()
    }
}

/** One visible menu row: token identity plus the resolved label (rules 2-5). */
public data class ContextMenuItem(
    public val surfaceId: String,
    /** Position in the surface's token table; stable while the contract order is. */
    public val order: Int,
    public val label: String,
    public val role: TokenContextMenuRole,
    public val kind: TokenContextMenuKind,
    public val dividerBefore: Boolean,
) {
    /** Rule 3: the renderer uses the platform's destructive (red) treatment. */
    public val isDestructive: Boolean get() = role == TokenContextMenuRole.DESTRUCTIVE

    /** Rule 4: `info` is a non-clickable explanation row, never an action. */
    public val isInfo: Boolean get() = kind == TokenContextMenuKind.INFO

    /** Rule 4: `share` goes to the caller's system share-sheet callback. */
    public val isShare: Boolean get() = kind == TokenContextMenuKind.SHARE
}

/**
 * Pure projection of `interaction.contextMenu.surfaces` (spec/ui/v1/interaction.md §3).
 *
 * Rule 2 keeps the token order and removes items whose `when` is false; it never
 * emits a disabled placeholder. Rule 3 carries `dividerBefore` for the renderer.
 */
public object ContextMenuModel {
    /** Every surface in the frozen table, in contract order. */
    public val surfaces: List<TokenContextMenuSurface> get() = UiTokenData.contextMenu.surfaces

    /** Fails loud for a surface id the frozen contract does not list. */
    public fun surface(surfaceId: String): TokenContextMenuSurface =
        surfaces.firstOrNull { it.id == surfaceId }
            ?: error("unknown context-menu surface '$surfaceId' (interaction.contextMenu.surfaces)")

    /**
     * Rules 2-5: visible items in token order with labels resolved.
     *
     * Hidden items are absent, not disabled; `botHidden` selects `altLabel`; and
     * `dividerBefore` is passed through so the renderer can draw the divider
     * before exactly the rows the contract marks.
     */
    public fun items(surfaceId: String, state: ContextMenuRowState): List<ContextMenuItem> =
        surface(surfaceId).items.mapIndexedNotNull { order, token ->
            if (!state.shows(token.whenCondition)) return@mapIndexedNotNull null
            ContextMenuItem(
                surfaceId = surfaceId,
                order = order,
                label = resolvedLabel(token, state),
                role = token.role,
                kind = token.kind,
                dividerBefore = token.dividerBefore,
            )
        }

    private fun resolvedLabel(token: TokenContextMenuItem, state: ContextMenuRowState): String =
        if (state.botHidden) token.altLabel ?: token.label else token.label
}

/**
 * Rule 7's one-action-per-open gate.
 *
 * The renderer opens a session on long press. [select] closes it *before*
 * returning the selected row, and refuses every later selection until a new
 * [open], so a rapid double tap cannot run two actions for one open.
 */
public class ContextMenuSession {
    private var open = false
    private var dispatched = false

    /** True between a successful [open] and [select]/[dismiss]. */
    public val isOpen: Boolean get() = open

    /** Starts a new one-action session; false when one is already open. */
    public fun open(): Boolean {
        if (open) return false
        open = true
        dispatched = false
        return true
    }

    /** Closes without running an action (outside tap / system back). */
    public fun dismiss() {
        open = false
    }

    /** Closes first, then returns [item], or null when no action is owed. */
    public fun select(item: ContextMenuItem): ContextMenuItem? {
        if (!open || dispatched) return null
        open = false
        dispatched = true
        return item
    }
}

