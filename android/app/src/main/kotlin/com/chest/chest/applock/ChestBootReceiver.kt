package com.chest.chest.applock

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-applies the recorded hidden state after a reboot or an app update.
 *
 * The platform enforces `setApplicationHidden` itself, so a hidden app normally
 * stays hidden across a reboot without Chest running. This receiver exists for
 * the two cases where the platform's own enforcement is not enough:
 *
 *  - **Boot.** Hidden packages are persistent, but a package can be reinstalled
 *    or an OEM build can drop the state. Re-applying makes the freeze
 *    self-healing rather than dependent on a write that may have failed.
 *  - **Update.** `MY_PACKAGE_REPLACED` fires when Chest itself is upgraded, which
 *    is the moment a botched migration would otherwise strand apps hidden with
 *    no way to restore them.
 *
 * Reconciliation is idempotent: [ChestAppLockManager.reconcile] only calls the
 * platform for packages that are not already hidden.
 *
 * Only `BOOT_COMPLETED` is handled, not `LOCKED_BOOT_COMPLETED`. The frozen set
 * lives in credential-encrypted preferences, which are unreadable until the user
 * unlocks, so handling direct boot would read an empty set and could unhide
 * nothing while appearing to succeed.
 */
class ChestBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        try {
            ChestAppLockManager.reconcile(context)
        } catch (e: Exception) {
            // A receiver must never crash the process; the next boot retries.
            Log.w(TAG, "reconcile after $action failed", e)
        }
    }

    private companion object {
        const val TAG = "ChestBootReceiver"
    }
}
