package com.chest.chest.applock

import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import android.text.TextUtils

/**
 * Persistent state for the app freezer.
 *
 * This store deliberately lives *outside* the encrypted vault. The accessibility
 * service and the device-admin receiver run in processes and moments where the
 * vault key is not available — for example, seconds after boot, before the user
 * has typed anything — so they need to read the frozen set without a passphrase.
 *
 * The trade-off is explicit and bounded: what is stored here is a list of
 * package names the user chose to freeze. Package names are public information
 * on the device (any app can enumerate them), so this leaks nothing that was
 * secret. Everything the user actually wants hidden — file contents, vault
 * entries, recovery material — stays inside the Argon2id/HKDF/AES-GCM/
 * XChaCha20-Poly1305 cascade and is never written here.
 */
object ChestAppLockStore {

    private const val PREFS_NAME = "chest_app_lock"
    private const val KEY_FROZEN = "frozen_packages"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** Package names the user has frozen, in no particular order. */
    fun frozenPackages(context: Context): List<String> =
        prefs(context).getStringSet(KEY_FROZEN, emptySet())?.sorted() ?: emptyList()

    /** Adds [packageName] to the frozen set. Returns true if it was newly added. */
    fun freeze(context: Context, packageName: String): Boolean {
        val current = frozenPackages(context).toMutableSet()
        if (!current.add(packageName)) return false
        write(context, current)
        return true
    }

    /** Removes [packageName] from the frozen set. Returns true if it was present. */
    fun unfreeze(context: Context, packageName: String): Boolean {
        val current = frozenPackages(context).toMutableSet()
        if (!current.remove(packageName)) return false
        write(context, current)
        return true
    }

    /** Clears the frozen set entirely. */
    fun clear(context: Context) {
        prefs(context).edit().remove(KEY_FROZEN).apply()
    }

    private fun write(context: Context, packages: Set<String>) {
        // getStringSet returns a set the framework may reuse, so hand it a copy.
        prefs(context).edit().putStringSet(KEY_FROZEN, HashSet(packages)).apply()
    }

    /**
     * Reports whether an accessibility service is currently enabled.
     *
     * Android has no direct API for this, so the enabled-services setting is
     * parsed and matched by flattened component name. Matching by
     * [Class.getCanonicalName] rather than a hardcoded string keeps the check
     * correct if the package is renamed.
     */
    fun isAccessibilityServiceEnabled(context: Context, serviceClass: Class<*>): Boolean {
        val expected = ComponentName(context, serviceClass).flattenToString()
        val expectedShort = ComponentName(context, serviceClass).flattenToShortString()
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
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
