package com.chest.chest

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.view.WindowManager
import com.chest.chest.applock.ChestAppLockManager
import com.chest.chest.applock.ChestDeviceAdminReceiver
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/**
 * Host activity and the single bridge between Dart and the Android platform.
 *
 * Only two capabilities need native code, and both are things Dart genuinely
 * cannot do:
 *
 *  - **App freezing**, which depends on [DevicePolicyManager] and an
 *    accessibility service.
 *  - **Hardware security reporting**, so the UI can tell the user whether the
 *    vault's key material is held in a TEE or a discrete security chip rather
 *    than merely claiming "hardware-backed".
 *
 * All cryptography stays in Dart, which keeps the cipher cascade auditable in
 * one language and testable with plain `flutter test`.
 */
class MainActivity : FlutterActivity() {

    private val appLockChannel = "com.chest.chest/app_lock"
    private val securityChannel = "com.chest.chest/security"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appLockChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "listApps" -> result.success(ChestAppLockManager.listApps(this))
                        "freeze" -> withPackage(call, result) { pkg ->
                            val label = call.argument<String>("label") ?: pkg
                            result.success(ChestAppLockManager.freeze(this, pkg, label))
                        }
                        "unfreeze" -> withPackage(call, result) { pkg ->
                            result.success(ChestAppLockManager.unfreeze(this, pkg))
                        }
                        "unhideAll" -> result.success(ChestAppLockManager.unhideAll(this))
                        "capabilities" -> result.success(capabilities())
                        "setSecureFlag" -> {
                            // Blocks screenshots and blanks the recents thumbnail.
                            // Applied by the Dart layer while the vault is
                            // unlocked, and cleared when it locks.
                            val enabled = call.argument<Boolean>("enabled") ?: true
                            if (enabled) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(true)
                        }
                        "requestDeviceAdmin" -> {
                            requestDeviceAdmin()
                            result.success(true)
                        }
                        "openAccessibilitySettings" -> {
                            startActivity(
                                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                            result.success(true)
                        }
                        "openAppDetailsSettings" -> {
                            val pkg = call.argument<String>("packageName")
                            val intent = if (pkg.isNullOrEmpty()) {
                                Intent(Settings.ACTION_SETTINGS)
                            } else {
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.fromParts("package", pkg, null),
                                )
                            }
                            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("app_lock_failure", e.message, null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, securityChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "hardwareSecurity" -> result.success(hardwareSecurity())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("security_probe_failure", e.message, null)
                }
            }
    }

    /** Runs [body] with the required `packageName` argument, or fails the call. */
    private inline fun withPackage(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
        body: (String) -> Unit,
    ) {
        val packageName = call.argument<String>("packageName")
        if (packageName.isNullOrEmpty()) {
            result.error("invalid_argument", "packageName is required", null)
        } else {
            body(packageName)
        }
    }

    /** Current enforcement state, so the UI can show what is actually active. */
    private fun capabilities(): Map<String, Any> = mapOf(
        "deviceOwnerActive" to ChestAppLockManager.isDeviceOwner(this),
        "profileOwnerActive" to ChestAppLockManager.isProfileOwner(this),
        "deviceAdminActive" to ChestAppLockManager.isDeviceAdminActive(this),
        "accessibilityEnabled" to ChestAppLockManager.isAccessibilityEnabled(this),
        "canHideApps" to ChestAppLockManager.canHideApps(this),
        "hiddenCount" to ChestAppLockManager.hiddenCount(this),
        "sdkInt" to Build.VERSION.SDK_INT,
        "packageName" to packageName,
    )

    /** Opens the system dialog that grants Chest device-admin rights. */
    private fun requestDeviceAdmin() {
        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
            putExtra(
                DevicePolicyManager.EXTRA_DEVICE_ADMIN,
                ComponentName(this@MainActivity, ChestDeviceAdminReceiver::class.java),
            )
            putExtra(
                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                getString(R.string.device_admin_description),
            )
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /**
     * Reports where the Android Keystore actually holds its key material.
     *
     * `isInsideSecureHardware` distinguishes a TEE-backed key from one the
     * platform merely keeps in software, and StrongBox detection reports a
     * discrete tamper-resistant chip. The UI uses this to describe protection
     * truthfully instead of asserting "hardware-backed" on every device.
     */
    private fun hardwareSecurity(): Map<String, Any> {
        val result = mutableMapOf<String, Any>(
            "sdkInt" to Build.VERSION.SDK_INT,
            "keystoreAvailable" to false,
            "strongBoxAvailable" to false,
            "insideSecureHardware" to false,
        )
        try {
            loadKeyStore()
            result["keystoreAvailable"] = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                result["strongBoxAvailable"] = packageManager.hasSystemFeature(
                    android.content.pm.PackageManager.FEATURE_STRONGBOX_KEYSTORE,
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                result["insideSecureHardware"] = probeSecureHardware()
            }
        } catch (e: Exception) {
            result["error"] = e.message ?: "keystore probe failed"
        }
        return result
    }

    /**
     * Creates a throwaway AES key and asks the platform whether it is
     * hardware-bound, then deletes it. Nothing is persisted and no vault
     * material is touched.
     */
    private fun probeSecureHardware(): Boolean {
        val alias = "chest.probe.${System.nanoTime()}"
        return try {
            val generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                ANDROID_KEYSTORE,
            )
            generator.init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            val key: SecretKey = generator.generateKey()
            val factory = SecretKeyFactory.getInstance(key.algorithm, ANDROID_KEYSTORE)
            @Suppress("DEPRECATION")
            val info = factory.getKeySpec(key, KeyInfo::class.java) as KeyInfo
            val hardware = info.isInsideSecureHardware
            loadKeyStore().deleteEntry(alias)
            hardware
        } catch (e: Exception) {
            runCatching { loadKeyStore().deleteEntry(alias) }
            false
        }
    }

    private fun loadKeyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
    }
}
