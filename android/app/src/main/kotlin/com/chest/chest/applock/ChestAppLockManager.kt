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
    val hidden: Boolean,
)

/**
 * Enumerates launchable apps and applies hide/unhide.
 *
 * Hiding is done with `DevicePolicyManager.setApplicationHidden`, which removes
 * the package from the launcher, makes it unlaunchable, and leaves its data
 * intact. The operation is fully reversible and the platform enforces it, so a
 * hidden app stays hidden across reboots without Chest running.
 *
 * That call requires the caller to be a **device owner or profile owner**.
 * Legacy device-admin rights are not sufficient: the platform throws
 * `SecurityException` for a legacy admin targeting API 24 or above. Chest
 * targets a modern API level, so device-admin alone can never hide anything —
 * this is why the app asks for device-owner provisioning instead.
 *
 * When Chest is not device owner, freezing degrades to the soft tier: the
 * package is recorded locally and [ChestAppLockService] bounces the user home
 * when it comes to the foreground. That is a weaker guarantee, and the result
 * map says so rather than pretending the two are equivalent.
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

    /**
     * Returns every launchable app, annotated with its current freeze state.
     *
     * Hidden packages are merged back in from the local store. A hidden package
     * is not returned by `queryIntentActivities` at all, so without this step the
     * user would be unable to see — and therefore unable to unhide — exactly the
     * apps they had frozen.
     */
    fun listApps(context: Context): List<Map<String, Any>> {
        val pm = context.packageManager
        val intent = android.content.Intent(android.content.Intent.ACTION_MAIN).apply {
            addCategory(android.content.Intent.CATEGORY_LAUNCHER)
        }
        @Suppress("DEPRECATION")
        val resolved = pm.queryIntentActivities(intent, 0)
        val frozen = ChestAppLockStore.frozenPackages(context).toSet()
        val labels = ChestAppLockStore.labels(context)
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
            val isFrozen = frozen.contains(packageName)
            apps[packageName] = InstalledApp(
                packageName = packageName,
                label = label,
                isSystem = isSystem,
                frozen = isFrozen,
                hidden = isFrozen && isHidden(context, packageName),
            )
        }

        // Re-add frozen packages that no longer resolve, using the label cached
        // at freeze time. Their hidden state is confirmed against the platform.
        for (packageName in frozen) {
            if (apps.containsKey(packageName)) continue
            if (PROTECTED_PACKAGES.contains(packageName)) continue
            apps[packageName] = InstalledApp(
                packageName = packageName,
                label = labels[packageName] ?: packageName,
                isSystem = false,
                frozen = true,
                hidden = isHidden(context, packageName),
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
                    "hidden" to it.hidden,
                )
            }
    }

    /**
     * Hides [packageName].
     *
     * Returns a map with `applied` (whether the platform hid the app) and
     * `method` (`"device_owner"`, `"device_admin"` or `"soft"`).
     */
    fun freeze(context: Context, packageName: String, label: String): Map<String, Any> {
        if (PROTECTED_PACKAGES.contains(packageName)) {
            return mapOf("applied" to false, "method" to "protected")
        }
        val hidden = setHidden(context, packageName, hidden = true)
        if (hidden) {
            // Only record a package we actually hid. Recording a package that is
            // still visible would leave the UI claiming a freeze that is not in
            // force, and the boot receiver would keep re-applying nothing.
            ChestAppLockStore.freeze(context, packageName, label)
        }
        broadcastFrozenSetChanged(context)
        return mapOf(
            "applied" to hidden,
            "method" to when {
                hidden && isDeviceOwner(context) -> "device_owner"
                hidden -> "device_admin"
                else -> "soft"
            },
        )
    }

    /**
     * Unhides [packageName].
     *
     * Unhiding is attempted even when the package is absent from the local
     * store, so a freeze recorded by an earlier version of Chest is still
     * reversible.
     */
    fun unfreeze(context: Context, packageName: String): Map<String, Any> {
        val unhidden = setHidden(context, packageName, hidden = false)
        ChestAppLockStore.unfreeze(context, packageName)
        broadcastFrozenSetChanged(context)
        return mapOf(
            "applied" to unhidden,
            "method" to if (unhidden) "device_owner" else "soft",
        )
    }

    /**
     * Unhides every package Chest recorded as frozen.
     *
     * This is the escape hatch. If a freeze ever leaves the device in a state the
     * user cannot undo through the normal list, this restores everything in one
     * call. It iterates the local record rather than asking the platform, because
     * there is no API that enumerates hidden packages.
     */
    fun unhideAll(context: Context): Map<String, Any> {
        val recorded = ChestAppLockStore.frozenPackages(context)
        var restored = 0
        var failed = 0
        for (packageName in recorded) {
            if (setHidden(context, packageName, hidden = false)) restored++ else failed++
        }
        ChestAppLockStore.clear(context)
        broadcastFrozenSetChanged(context)
        return mapOf(
            "applied" to (failed == 0),
            "restored" to restored,
            "failed" to failed,
            "method" to "device_owner",
        )
    }

    /**
     * Re-applies the recorded hidden state to the platform.
     *
     * Run at boot and after an app update, so a crash or a failed write cannot
     * leave an app hidden with no record of how to restore it — or conversely,
     * leave the store claiming a hide the platform has forgotten.
     */
    fun reconcile(context: Context) {
        if (!isDeviceOwner(context) && !isProfileOwner(context)) return
        val recorded = ChestAppLockStore.frozenPackages(context)
        if (recorded.isEmpty()) return
        for (packageName in recorded) {
            if (!isHidden(context, packageName)) {
                Log.i(TAG, "re-applying hidden state for $packageName")
                setHidden(context, packageName, hidden = true)
            }
        }
    }

    /** True when Chest is the device owner. */
    fun isDeviceOwner(context: Context): Boolean {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            ?: return false
        return dpm.isDeviceOwnerApp(context.packageName)
    }

    /** True when Chest is a profile owner. */
    fun isProfileOwner(context: Context): Boolean {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            ?: return false
        return dpm.isProfileOwnerApp(context.packageName)
    }

    /** True when Chest holds legacy device-admin rights. */
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
     * True when the platform will accept a hide request.
     *
     * Device owner and profile owner both satisfy the platform's permission
     * check; legacy device admin does not.
     */
    fun canHideApps(context: Context): Boolean = isDeviceOwner(context) || isProfileOwner(context)

    /** Number of packages Chest currently has hidden. */
    fun hiddenCount(context: Context): Int =
        ChestAppLockStore.frozenPackages(context).count { isHidden(context, it) }

    /**
     * Reports whether [packageName] is hidden.
     *
     * Returns false when Chest lacks the rights to ask, which keeps the UI from
     * claiming a hidden state it cannot substantiate.
     */
    private fun isHidden(context: Context, packageName: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            ?: return false
        if (!canHideApps(context)) return false
        val admin = ComponentName(context, ChestDeviceAdminReceiver::class.java)
        return try {
            dpm.isApplicationHidden(admin, packageName)
        } catch (e: SecurityException) {
            Log.w(TAG, "isApplicationHidden($packageName) refused", e)
            false
        }
    }

    /**
     * Calls [DevicePolicyManager.setApplicationHidden].
     *
     * `setApplicationHidden` is API 21+ and, from API 24, is restricted to device
     * and profile owners. When Chest holds neither, this returns false and the
     * caller falls back to the soft tier rather than reporting a freeze that did
     * not happen.
     */
    private fun setHidden(context: Context, packageName: String, hidden: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
            ?: return false
        if (!canHideApps(context)) {
            Log.i(TAG, "not device/profile owner; $packageName stays soft-frozen")
            return false
        }
        val admin = ComponentName(context, ChestDeviceAdminReceiver::class.java)
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
