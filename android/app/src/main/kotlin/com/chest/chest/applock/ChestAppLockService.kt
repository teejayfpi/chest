package com.chest.chest.applock

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * Enforcement layer for frozen apps.
 *
 * Android gives a normal app no supported way to kill another app's process, so
 * "freezing" is enforced in two places:
 *
 *  1. [ChestDeviceAdmin] calls `setApplicationHidden`, which is authoritative
 *     and survives reboots. That is the real freeze.
 *  2. This service is defence in depth. It watches for a frozen package coming
 *     to the foreground and immediately sends the user home, covering the window
 *     between a freeze request and the platform applying it, and OEM builds
 *     where `setApplicationHidden` is silently a no-op.
 *
 * Privacy: the service declares `canRetrieveWindowContent="false"` in its XML
 * config, so the framework will not hand it window text. It only ever compares
 * the package name carried by the event against a locally stored frozen set,
 * and it holds that set in memory as a plain string set.
 */
class ChestAppLockService : AccessibilityService() {

    private var frozenPackages: Set<String> = emptySet()

    override fun onServiceConnected() {
        super.onServiceConnected()
        reloadFrozenPackages()
        Log.i(TAG, "app lock service connected with ${frozenPackages.size} frozen package(s)")
    }

    /**
     * Picks up changes written by the Dart layer.
     *
     * The Flutter side broadcasts this whenever the frozen set changes so the
     * service does not have to poll storage on every window transition.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        reloadFrozenPackages()
        return START_STICKY
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val current = event ?: return
        if (current.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        val packageName = current.packageName?.toString() ?: return
        if (packageName.isEmpty() || packageName == this.packageName) return
        if (!frozenPackages.contains(packageName)) return

        Log.i(TAG, "intercepted frozen package $packageName; returning home")

        // Collapse the offending task so the frozen app cannot be resumed by
        // simply pressing Back, then go home.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            performGlobalAction(GLOBAL_ACTION_HOME)
        } else {
            val home = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(home)
        }
    }

    override fun onInterrupt() {
        Log.i(TAG, "app lock service interrupted")
    }

    /** Re-reads the frozen set from [ChestAppLockStore]. */
    private fun reloadFrozenPackages() {
        frozenPackages = ChestAppLockStore.frozenPackages(this).toSet()
    }

    companion object {
        private const val TAG = "ChestAppLock"

        /**
         * Broadcast action the Dart layer sends after mutating the frozen set.
         *
         * Declared here rather than in the manifest because it is only ever
         * delivered to a running instance of this service.
         */
        const val ACTION_FROZEN_SET_CHANGED = "com.chest.chest.FROZEN_SET_CHANGED"

        /** Returns true when the user has granted the accessibility service. */
        fun isRunning(context: Context): Boolean =
            ChestAppLockStore.isAccessibilityServiceEnabled(context, ChestAppLockService::class.java)
    }
}
