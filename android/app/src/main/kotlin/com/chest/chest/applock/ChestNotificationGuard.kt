package com.chest.chest.applock

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.text.TextUtils
import android.util.Log

/**
 * Dismisses notifications posted by frozen apps.
 *
 * This is a second, separate service because it has to be. An accessibility
 * service cannot dismiss another app's notification: `NotificationManager.cancel`
 * only affects the calling app's own notifications, and reading
 * `activeNotifications` to work around that is not permitted either. The only
 * supported mechanism is a [NotificationListenerService], which needs its own
 * user grant in Settings.
 *
 * Why it matters: a freeze that still lets a messenger buzz and print the message
 * text on the lock screen has not hidden anything worth hiding. Blocking the app
 * while its notifications stream through the shade is a freeze with a hole in it,
 * and it is the most common case the user cares about.
 *
 * Scope: only notifications whose package is in the locally stored frozen set are
 * touched, and only the notification's key is read — never its content. A frozen
 * app's notification is cancelled outright rather than hidden, so it does not sit
 * in the shade waiting to be read.
 *
 * Like the accessibility tier, this needs no computer and no factory reset: the
 * user grants notification access on the device itself.
 */
class ChestNotificationGuard : NotificationListenerService() {

    /**
     * Called for every notification posted on the device.
     *
     * The frozen set is read per call rather than cached. Notifications arrive
     * rarely compared with window transitions, so the read is cheap, and it means
     * a freeze or release takes effect immediately with no broadcast plumbing.
     */
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val posted = sbn ?: return
        val packageName = posted.packageName ?: return
        if (packageName == applicationContext.packageName) return

        val frozen = try {
            ChestAppLockStore.frozenPackages(applicationContext)
        } catch (e: Exception) {
            // A read failure must not take the service down; the next
            // notification retries.
            Log.w(TAG, "could not read frozen set", e)
            return
        }
        if (!frozen.contains(packageName)) return

        Log.i(TAG, "dismissing notification from frozen package $packageName")
        try {
            cancelNotification(posted.key)
        } catch (e: Exception) {
            // Some OEM builds refuse cancellation for certain packages. The
            // accessibility tier still blocks the app itself.
            Log.w(TAG, "could not cancel notification from $packageName", e)
        }
    }

    companion object {
        private const val TAG = "ChestNotificationGuard"

        /**
         * True when the user has granted Chest notification access.
         *
         * There is no direct API, so the enabled-listeners secure setting is
         * parsed and matched by flattened component name, the same way the
         * accessibility check works.
         */
        fun isEnabled(context: Context): Boolean {
            val expected = ComponentName(context, ChestNotificationGuard::class.java)
                .flattenToString()
            val expectedShort = ComponentName(context, ChestNotificationGuard::class.java)
                .flattenToShortString()
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners",
            ) ?: return false

            val splitter = TextUtils.SimpleStringSplitter(':')
            splitter.setString(enabled)
            for (component in splitter) {
                if (component.equals(expected, ignoreCase = true) ||
                    component.equals(expectedShort, ignoreCase = true)
                ) {
                    return true
                }
            }
            return false
        }
    }
}
