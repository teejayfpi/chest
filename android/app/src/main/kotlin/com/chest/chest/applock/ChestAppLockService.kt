package com.chest.chest.applock

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

import com.chest.chest.R

/**
 * Enforcement layer for frozen apps.
 *
 * Android gives a normal app no supported way to remove another app's icon from
 * the launcher — that needs device owner, which needs a computer and usually a
 * factory reset. This service is the phone-only tier: everything it does is
 * permitted by the single accessibility toggle the user grants on the device
 * itself, with no computer and no reset.
 *
 * What it enforces, and why each part matters:
 *
 *  1. **Block.** When a frozen package reaches the foreground, an opaque
 *     [WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY] covers the screen
 *     and the user is sent home. The overlay is the load-bearing part: the home
 *     transition takes a few frames, and without it a frozen app is briefly
 *     readable — the last message on a messenger, the last photo in a gallery.
 *     `TYPE_ACCESSIBILITY_OVERLAY` needs no `SYSTEM_ALERT_WINDOW` permission;
 *     holding the accessibility service is itself the grant.
 *  2. **Leave the task.** The user is sent home, and the shield lowers itself
 *     again shortly after. The delay is deliberate: it keeps the frozen app
 *     covered for the whole home transition, then clears so the user is not left
 *     staring at an overlay on their home screen.
 *
 * Notifications from frozen packages are a separate concern and live in
 * [ChestNotificationGuard], because dismissing another app's notification is not
 * something an accessibility service can do.
 *
 * Privacy: the service declares `canRetrieveWindowContent="false"` in its XML
 * config, so the framework will not hand it window text. It only ever compares
 * the package name carried by the event against a locally stored frozen set, and
 * holds that set in memory as a plain string set.
 */
class ChestAppLockService : AccessibilityService() {

    private var windowManager: WindowManager? = null
    private var shieldView: View? = null

    /**
     * The package the shield is currently covering.
     *
     * Tracked so the overlay is added once per intrusion rather than on every
     * window event, which would leak views and flicker.
     */
    private var shieldedPackage: String? = null

    /** Pending auto-lower for the shield, so it can be replaced or cancelled. */
    private var shieldTimeout: Runnable? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        reloadFrozenPackages()
        Log.i(TAG, "app lock service connected with ${FrozenSetRegistry.current(this).size} frozen package(s)")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        reloadFrozenPackages()
        return START_STICKY
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val current = event ?: return

        // Only window-state changes are handled. TYPE_WINDOWS_CHANGED would be a
        // useful extra signal, but the platform only delivers it when the service
        // declares canRetrieveWindowContent="true", and Chest deliberately does
        // not: this service must be incapable of reading screen text. Window
        // state changes carry the foreground package name, which is all the
        // block needs.
        if (current.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        handleForegroundChange(current)
    }

    /**
     * Blocks a frozen package that has come to the foreground.
     *
     * Raises the shield first and navigates second. Order matters: the overlay is
     * what hides the app's content, and every millisecond between the app
     * becoming visible and going home is a millisecond its content is readable.
     */
    private fun handleForegroundChange(event: AccessibilityEvent) {
        val packageName = event.packageName?.toString() ?: return
        if (packageName.isEmpty() || packageName == this.packageName) return

        if (!FrozenSetRegistry.current(this).contains(packageName)) {
            // The user has landed somewhere that is not frozen, so the shield has
            // done its job and must come down. Without this the overlay would sit
            // over the home screen and the user would be locked out of the phone.
            if (shieldedPackage != null) lowerShield()
            return
        }

        showShield(packageName)
        Log.i(TAG, "blocked frozen package $packageName")

        // Go home so the frozen app is no longer the foreground task. The shield
        // stays up briefly to cover the transition, then lowers itself.
        performGlobalAction(GLOBAL_ACTION_HOME)
    }

    /**
     * Adds the opaque shield over whatever is currently on screen.
     *
     * The layout is `clickable` so touches land on the shield rather than passing
     * through to the frozen app underneath, which would let the user interact
     * with a blocked app by tapping blindly.
     */
    private fun showShield(packageName: String) {
        if (shieldedPackage == packageName && shieldView != null) {
            // Already covering this package; just extend the time it stays up.
            scheduleLowerShield()
            return
        }
        lowerShield()

        val manager = windowManager ?: return
        val view = try {
            LayoutInflater.from(this).inflate(R.layout.chest_freeze_shield, null)
        } catch (e: Exception) {
            // A missing layout must not break blocking; the home action alone
            // still stops the app, just with a brief window where it is visible.
            Log.w(TAG, "could not inflate freeze shield", e)
            return
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            // Not focusable, so the keyguard and system dialogs keep working.
            // The overlay is a visual block, not a window that steals input
            // focus from the system.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        try {
            manager.addView(view, params)
            shieldView = view
            shieldedPackage = packageName
            scheduleLowerShield()
        } catch (e: Exception) {
            // Some OEM builds reject overlays from accessibility services. The
            // home action still fires, so the freeze degrades to the pre-overlay
            // behaviour rather than failing outright.
            Log.w(TAG, "could not add freeze shield", e)
        }
    }

    /**
     * Arranges for the shield to come down once the home transition has settled.
     *
     * Without this the overlay would be permanent: it is added over the frozen app
     * and nothing else would ever remove it, leaving the user with a full-screen
     * block over their home screen. The short delay keeps the frozen app covered
     * through the transition while still clearing on its own.
     */
    private fun scheduleLowerShield() {
        cancelLowerShield()
        val pending = Runnable { lowerShield() }
        shieldTimeout = pending
        shieldView?.postDelayed(pending, SHIELD_LINGER_MS)
    }

    /** Cancels a scheduled lower, so a new block can take over cleanly. */
    private fun cancelLowerShield() {
        val pending = shieldTimeout ?: return
        shieldTimeout = null
        shieldView?.removeCallbacks(pending)
    }

    /**
     * Removes the shield, if one is showing.
     *
     * Also called when the foreground leaves a frozen package, so the overlay is
     * never left over an app the user is allowed to use.
     */
    private fun lowerShield() {
        cancelLowerShield()
        val view = shieldView ?: return
        shieldView = null
        shieldedPackage = null
        try {
            windowManager?.removeViewImmediate(view)
        } catch (e: Exception) {
            // Already detached by the framework; nothing to undo.
            Log.d(TAG, "freeze shield already detached", e)
        }
    }

    override fun onInterrupt() {
        Log.i(TAG, "app lock service interrupted")
    }

    override fun onDestroy() {
        // Leaving a full-screen overlay behind after the service dies would lock
        // the user out of their own phone, so the shield never outlives us.
        lowerShield()
        super.onDestroy()
    }

    /** Re-reads the frozen set from the process-wide registry. */
    private fun reloadFrozenPackages() {
        // Read from the shared registry rather than storage: the registry is what
        // the freeze call writes to, so a freeze takes effect immediately without
        // a broadcast round trip. The registry also refreshes itself from storage
        // when empty, which covers the case where the service starts before any
        // freeze has happened in this process.
        val current = FrozenSetRegistry.current(this)

        // A package released while the shield was up must not stay covered.
        val covered = shieldedPackage
        if (covered != null && !current.contains(covered)) lowerShield()
    }

    companion object {
        private const val TAG = "ChestAppLock"

        /**
         * How long the shield stays up after a block, in milliseconds.
         *
         * Long enough to cover the home transition and the first frame of the
         * launcher, short enough that the user is not left staring at an overlay
         * on their home screen.
         */
        private const val SHIELD_LINGER_MS = 900L

        /** Returns true when the user has granted the accessibility service. */
        fun isRunning(context: Context): Boolean =
            ChestAppLockStore.isAccessibilityServiceEnabled(context, ChestAppLockService::class.java)
    }
}
