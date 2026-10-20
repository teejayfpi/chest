package com.chest.chest.applock

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log

/**
 * A launchable app on the device, as reported to the Chest UI.
 *
 * Data is a plain map so it can cross the method channel without codegen.
 */
data class InstalledApp(
    val packageName: String,
    val label: String,
    val isSystem: Boolean,
    val frozen: Boolean,
)

/**
 * Enumerates launchable apps and applies freeze/unfreeze.
 *
 * Freezing has two tiers, and the class always attempts the strong one first:
 *
 *  - **Device-admin tier.** `setApplicationHidden` asks the platform to disable
 *    the package outright. The app disappears from the launcher, cannot be
 *    started, and stays that way across reboots because the platform enforces
 *    it. This is what makes a freeze a real freeze rather than a UI trick.
 *
 *  - **Soft tier.** When admin rights have not been granted, or the device
 *    refuses the call, the package is only recorded locally. It still shows in
 *    the launcher, but [ChestAppLockService] bounces the user home the moment it
 *    comes to the foreground.
 *
 * The result carries which tier was used so the UI can be honest with the user
 * about how strong the freeze currently is.
 */
object ChestAppLockManager {

    private const val TAG = "ChestAppLockManager"

    /**
     * Packages that must never appear in the freeze list.
     *
     * Hiding the launcher, the settings app or the IME would leave the user
     * unable to undo the freeze, which is a foot-gun rather than a feature.
     */
    private val PROTECTED_PACKAGES = setOf(
        "com.android.settings",
        "com.android.systemui",
        "com.google.android.settings",
        "com.android.launcher",
        "com.android.launcher3",
        "com.google.android.apps.nexuslauncher",
        "com.android.inputmethod.latin",
    )

    /** Returns every launchable app, annotated with its current freeze state. */
    fun listApps(context: Context): List<Map<String, Any>> {
        val pm = context.packageManager
        val intent = android.content.Intent(android.content.Intent.ACTION_MAIN).apply {
            addCategory(android.content.Intent.CATEGORY_LAUNCHER)
        }
        @Suppress("DEPRECATION")
        val resolved = pm.queryIntentActivities(intent, 0)
        val frozen = ChestAppLockStore.frozenPackages(context).toSet()
        val self = context.packageName

        val apps = LinkedHashMap<String, InstalledApp>()
        for (info in resolved) {
            val packageName = info.activityInfo?.packageName ?: continue
            if (packageName == self) continue
            if (PROTECTED_PACKAGES.contains(packageName)) continue
            if (apps.containsKey(packageName)) continue

            val appInfo: ApplicationInfo = try {
                pm.getApplicationInfo(packageName, 0)
            } catch (e: PackageManager.NameNotFoundException) {
                continue
            }

            val label = pm.getApplicationLabel(appInfo).toString()
            val isSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            apps[packageName] = InstalledApp(
                packageName = packageName,
                label = label,
                isSystem = isSystem,
                frozen = frozen.contains(packageName),
            )
        }

        return apps.values
            .sortedWith(compareBy({ it.label.lowercase() }, { it.packageName }))
            .map {
                mapOf(
                    "packageName" to it.packageName,
                    "label" to it.label,
                    "isSystem" to it.isSystem,
                    "frozen" to it.frozen,
                )
            }
    }

    /**
     * Freezes [packageName].
     *
     * Returns a map with `applied` (whether the platform hid the app) and
     * `method` (`"device_admin"` or `"soft"`).
     */
    fun freeze(context: Context, packageName: String): Map<String, Any> {
        if (PROTECTED_PACKAGES.contains(packageName)) {
            return mapOf("applied" to false, "method" to "protected")
        }
        ChestAppLockStore.freeze(context, packageName)
        val hidden = setHidden(context, packageName, hidden = true)
        broadcastFrozenSetChanged(context)
        return mapOf(
            "applied" to hidden,
            "method" to if (hidden) "device_admin" else "soft",
        )
    }

    /**
     * Unfreezes [packageName].
     *
     * Unhiding is always attempted first so that a previously device-admin
     * freeze is fully reversed even if the local record was lost.
     */
    fun unfreeze(context: Context, packageName: String): Map<String, Any> {
        val unhidden = setHidden(context, packageName, hidden = false)
        ChestAppLockStore.unfreeze(context, packageName)
        broadcastFrozenSetChanged(context)
        return mapOf(
            "applied" to unhidden,
            "method" to if (unhidden) "device_admin" else "soft",
        )
    }

    /** True when Chest currently holds device-admin rights. */
    fun isDeviceAdminActive(context: Context): Boolean {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            ?: return false
        val admin = ComponentName(context, ChestDeviceAdminReceiver::class.java)
        return dpm.isAdminActive(admin)
    }

    /** True when the enforcement accessibility service is enabled. */
    fun isAccessibilityEnabled(context: Context): Boolean =
        ChestAppLockStore.isAccessibilityServiceEnabled(context, ChestAppLockService::class.java)

    /**
     * Calls [DevicePolicyManager.setApplicationHidden].
     *
     * `setApplicationHidden` is API 21+. On older platforms this returns false
     * and the caller falls back to the soft tier. The `@Suppress` is for the
     * deprecated overload resolution on newer SDKs; the call itself is current.
     */
    private fun setHidden(context: Context, packageName: String, hidden: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            ?: return false
        val admin = ComponentName(context, ChestDeviceAdminReceiver::class.java)
        if (!dpm.isAdminActive(admin)) {
            Log.i(TAG, "device admin not active; $packageName stays soft-frozen")
            return false
        }
        return try {
            dpm.setApplicationHidden(admin, packageName, hidden)
        } catch (e: SecurityException) {
            // Some OEM builds reject hiding system or preinstalled packages.
            Log.w(TAG, "setApplicationHidden($packageName, $hidden) refused", e)
            false
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "setApplicationHidden($packageName, $hidden) rejected package", e)
            false
        }
    }

    /** Tells a running [ChestAppLockService] to re-read the frozen set. */
    private fun broadcastFrozenSetChanged(context: Context) {
        val intent = android.content.Intent(ChestAppLockService.ACTION_FROZEN_SET_CHANGED).apply {
            setPackage(context.packageName)
        }
        context.sendBroadcast(intent)
    }
}
