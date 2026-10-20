package com.chest.chest.applock

import android.content.Context

/**
 * In-process cache of the frozen package set.
 *
 * The accessibility service must see a freeze the instant it is applied: if it
 * kept its own copy, freezing an app and immediately opening it would slip
 * through until the service happened to restart. Passing the set through a
 * broadcast was the alternative, but a service that is not running yet would
 * miss it, which is the common case — the guard is usually idle when the user
 * taps freeze.
 *
 * Both the manager and the service run in the app's main process (neither
 * declares `android:process`), so a shared object is a reliable channel between
 * them. Storage remains the source of truth across restarts; this only avoids
 * re-reading it on every window transition.
 */
internal object FrozenSetRegistry {

    @Volatile
    private var cached: Set<String>? = null

    /** The current frozen set, loaded from storage on first use. */
    fun current(context: Context): Set<String> {
        cached?.let { return it }
        val loaded = ChestAppLockStore.frozenPackages(context).toSet()
        cached = loaded
        return loaded
    }

    /**
     * Re-reads storage after a freeze or release.
     *
     * Called by [ChestAppLockManager] once the write has landed, so the next
     * window transition already sees the new set.
     */
    fun refresh(context: Context) {
        cached = ChestAppLockStore.frozenPackages(context).toSet()
    }
}
