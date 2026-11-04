// One instance per process, for owners that must not be created twice.
// SPDX-License-Identifier: MIT

package com.phonedsh.probe

/**
 * A lazily created process-wide instance.
 *
 * `ProbeEngineViewModel` owns the one `WorkspaceLog` writer of this App
 * (`wal.md` §1, P02). Android can create a second `MainActivity` while the
 * first still has a live view model — a launcher start is a new instance, not
 * a configuration change — and two view models meant two `DefaultPhoneDshHost`
 * instances, two `WorkspaceLog` objects and two writers over the same
 * directory. The 2026-11-03 evidence shows exactly that: two `host boot` lines
 * with different `boot_id`s in one process, and the second engine refusing to
 * start because the process already owned two live WebViews.
 *
 * This holder is the in-process ownership primitive: the factory runs at most
 * once, and every caller gets the same object. `clear` exists for the one
 * legitimate release (the owner's `onCleared`); in the App the view model is
 * process-scoped, so the process itself is the release point.
 *
 * The synchronization is deliberately small: `@Volatile` makes the fast path
 * lock-free, and the double-checked creation runs under one monitor. Concurrent
 * first callers therefore construct exactly one instance.
 */
internal class ProcessSingleton<T : Any> {
    @Volatile
    private var instance: T? = null

    private val lock = Any()

    /** The current instance, or `null` before the first [obtain] / after [clear]. */
    fun peek(): T? = instance

    /**
     * Returns the instance, creating it with [create] only when none exists.
     *
     * @throws IllegalStateException when a concurrent creation produced an
     *   instance and the factory somehow returned a second one. That cannot
     *   happen with the monitor below; the check is here so a future refactor
     *   cannot quietly break the single-owner invariant.
     */
    fun obtain(create: () -> T): T {
        instance?.let { return it }
        synchronized(lock) {
            val existing = instance
            if (existing != null) return existing
            val created = create()
            instance = created
            return created
        }
    }

    /**
     * Releases [current] if it is the instance this holder owns.
     *
     * Passing a different object is a no-op: a stale owner must not clear a
     * newer instance.
     */
    fun clear(current: T) {
        synchronized(lock) {
            if (instance === current) instance = null
        }
    }
}
