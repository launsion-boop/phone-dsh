// The sheet layer of the system back chain, spec/ui/v1/interaction.md §2 rule 9.
// SPDX-License-Identifier: MIT
//
// W2-NAV owns the whole back order (`sheet,drawer,stack,root` in
// `interaction.md` §4 rule 5). This file is the sheet end of that boundary and
// deliberately names no navigation type: the coordinator calls
// [SheetBackHost.dispatch] for the sheet layer, and the content owner implements
// [SheetInnerNavigation] for a sheet-hosted stack.
package com.phonedsh.ui.sheet

/**
 * One navigation stack that lives inside a sheet (rule 9).
 *
 * A system back gesture leaves one destination of this stack before it may close
 * the sheet. Implement this in the sheet content; [PdshSheet] calls it through
 * [SheetBackHost], and the W2-NAV coordinator can call the same host without
 * depending on this package's composable.
 */
public fun interface SheetInnerNavigation {
    /**
     * Pops one inner destination.
     *
     * @return `true` when a destination was left; `false` at the inner stack's
     *   root, where the next back step closes the sheet.
     */
    public fun popInner(): Boolean
}

/**
 * Rule 9: the sheet layer of the back chain.
 *
 * Every mounted [PdshSheet] registers one level. [dispatch] acts on the most
 * recently registered level only, so a back gesture closes the top sheet and
 * never a lower one. Within that sheet an [SheetInnerNavigation] pops first;
 * only at its root does the sheet dismiss. A second back while the first
 * dismissal is still leaving is consumed by the same level, not passed down.
 *
 * The W2-NAV coordinator calls [dispatch] when its `sheet` layer is active and
 * falls through to drawer/stack/root when this returns `false`.
 */
public class SheetBackHost {
    private val entries: MutableList<Entry> = mutableListOf()

    /** Whether a mounted sheet owns the sheet layer right now. */
    public val hasSheet: Boolean get() = entries.isNotEmpty()

    /**
     * Leaves one back step in the top sheet.
     *
     * @return `true` when a sheet level consumed the gesture (an inner pop or a
     *   dismissal request); `false` when no sheet is mounted.
     */
    public fun dispatch(): Boolean {
        val top = entries.lastOrNull() ?: return false
        top.dispatch()
        return true
    }

    internal fun register(entry: Entry) {
        entries += entry
    }

    internal fun unregister(entry: Entry) {
        entries.remove(entry)
    }

    /** One sheet's back level; created by [PdshSheet]. */
    internal class Entry(
        private val popInner: () -> Boolean,
        private val dismiss: () -> Unit,
    ) {
        private var dismissed = false

        fun dispatch() {
            if (dismissed) return
            if (popInner()) return
            dismissed = true
            dismiss()
        }
    }
}
