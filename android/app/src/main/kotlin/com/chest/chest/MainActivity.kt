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
import androidx.activity.result.ActivityResultLauncher
import com.chest.chest.applock.ChestAppLockManager
import com.chest.chest.applock.ChestDeviceAdminReceiver
import com.chest.chest.files.ChestFilePicker
import com.chest.chest.files.ChestFileSealer
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/**
 * Host activity and the single bridge between Dart and the Android platform.
 *
 * Only three capabilities need native code, and each is something Dart
 * genuinely cannot do:
 *
 *  - **App freezing**, which depends on [DevicePolicyManager] and an
 *    accessibility service.
 *  - **Hardware security reporting**, so the UI can tell the user whether the
 *    vault's key material is held in a TEE or a discrete security chip rather
 *    than merely claiming "hardware-backed".
 *  - **File handling**, which needs a Storage Access Framework grant the user
 *    approves and a delete of the original once the vault holds a sealed copy.
 *
 * All cryptography stays in Dart, which keeps the cipher cascade auditable in
 * one language and testable with plain `flutter test`.
 *
 * The base class is [FlutterFragmentActivity] rather than `FlutterActivity`
 * because the file picker needs `registerForActivityResult`, which lives on
 * `ComponentActivity`. `FlutterActivity` extends a plain `Activity` and cannot
 * host an activity-result launcher.
 */
class MainActivity : FlutterFragmentActivity() {

    private val appLockChannel = "com.chest.chest/app_lock"
    private val securityChannel = "com.chest.chest/security"
    private val filesChannel = "com.chest.chest/files"

    /**
     * The picker result, parked until the picker closes.
     *
     * A method channel call cannot span the time the user spends in the system
     * picker, so `pickFiles` launches the picker and returns without completing
     * its result. The `MethodChannel.Result` is held here and completed from the
     * activity-result callback once the user is done, so the Dart `await` simply
     * stays pending until then. Flutter re-attaches the engine after the picker
     * closes, which is why the pending result has to survive the activity being
     * paused and resumed.
     */
    private var pendingPick: PendingPick? = null

    private var pickLauncher: ActivityResultLauncher<Intent>? = null

    private data class PendingPick(val result: MethodChannel.Result)

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Must be registered before the activity starts, which is why it lives
        // here rather than in configureFlutterEngine.
        pickLauncher = registerForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult(),
        ) { activityResult ->
            val pending = pendingPick ?: return@registerForActivityResult
            pendingPick = null
            if (activityResult.resultCode != RESULT_OK || activityResult.data == null) {
                pending.result.success(emptyList<Map<String, Any>>())
                return@registerForActivityResult
            }
            val data = activityResult.data!!
            val uris = ChestFilePicker.urisFrom(data)
            // Persist the grant for each file so the delete after sealing is
            // permitted, then describe it for the UI.
            val described = uris.map { uri ->
                ChestFilePicker.takeGrant(this, uri)
                ChestFilePicker.describe(this, uri)
            }
            pending.result.success(described)
        }
    }

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

        // File sealing and the outbound hand-offs. Kept on its own channel
        // because it needs the activity to launch intents, while the work
        // itself is a content-provider operation.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filesChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "pickFiles" -> {
                            // The result is completed later, when the picker
                            // closes, so Dart simply awaits the call.
                            val launcher = pickLauncher
                            if (launcher == null) {
                                result.error("no_launcher", "picker unavailable", null)
                            } else {
                                pendingPick = PendingPick(result)
                                try {
                                    launcher.launch(ChestFilePicker.buildPickIntent())
                                } catch (e: Exception) {
                                    pendingPick = null
                                    result.error("picker_failed", e.message, null)
                                }
                            }
                        }
                        "readPickedFile" -> {
                            val raw = call.argument<String>("uri")
                            val maxBytes = call.argument<Number>("maxBytes")?.toLong()
                                ?: DEFAULT_MAX_PICK_BYTES
                            if (raw.isNullOrEmpty()) {
                                result.error("invalid_argument", "uri is required", null)
                            } else {
                                val bytes = ChestFilePicker.readBytes(this, Uri.parse(raw), maxBytes)
                                if (bytes == null) {
                                    result.error(
                                        "read_failed",
                                        ChestFilePicker.error ?: "unreadable",
                                        null,
                                    )
                                } else {
                                    result.success(bytes)
                                }
                            }
                        }
                        "releaseSource" -> {
                            val raw = call.argument<String>("uri")
                            if (!raw.isNullOrEmpty()) {
                                ChestFilePicker.releaseGrant(this, Uri.parse(raw))
                            }
                            result.success(true)
                        }
                        "deleteSource" -> {
                            val raw = call.argument<String>("uri")
                            if (raw.isNullOrEmpty()) {
                                result.error("invalid_argument", "uri is required", null)
                            } else {
                                val outcome = ChestFileSealer.deleteSource(this, Uri.parse(raw))
                                result.success(
                                    mapOf(
                                        "removed" to outcome.removed,
                                        "reason" to outcome.reason,
                                    ),
                                )
                            }
                        }
                        "shareFile" -> {
                            val path = call.argument<String>("path")
                            val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                            if (path.isNullOrEmpty()) {
                                result.error("invalid_argument", "path is required", null)
                            } else {
                                val file = java.io.File(path)
                                if (!file.exists()) {
                                    result.error("missing_file", "nothing to share", null)
                                } else {
                                    startActivity(
                                        ChestFileSealer.shareIntent(
                                            this,
                                            file,
                                            mime,
                                            getString(R.string.share_file_title),
                                        ),
                                    )
                                    result.success(true)
                                }
                            }
                        }
                        "openWhatsApp" -> {
                            val phone = call.argument<String>("phone") ?: ""
                            // Two things can stop this working, and both are
                            // reported rather than papered over. Opening a
                            // browser fallback would be a network call made on
                            // the user's behalf, which this app does not do.
                            when {
                                !digitsPresent(phone) -> result.success(
                                    mapOf("opened" to false, "reason" to "no_phone_number"),
                                )
                                packageManager.getLaunchIntentForPackage(WHATSAPP_PACKAGE) == null ->
                                    result.success(
                                        mapOf("opened" to false, "reason" to "whatsapp_not_installed"),
                                    )
                                else -> {
                                    startActivity(ChestFileSealer.whatsappIntent(phone))
                                    result.success(mapOf("opened" to true, "reason" to null))
                                }
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("files_failure", e.message, null)
                }
            }
    }

    /** True when [phone] has enough digits to form a usable wa.me link. */
    private fun digitsPresent(phone: String): Boolean = phone.count { it.isDigit() } >= 7

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
        const val WHATSAPP_PACKAGE = "com.whatsapp"

        /**
         * Ceiling on a file read into memory for sealing.
         *
         * The bytes are held in memory because a cache file would be a
         * plaintext copy outside the vault, so this bound is what stops a
         * multi-gigabyte video from exhausting the heap. It is a hard refusal,
         * not a truncation: sealing part of a file would produce a vault entry
         * that silently decrypts to corrupt data.
         */
        const val DEFAULT_MAX_PICK_BYTES = 256L * 1024L * 1024L
    }
}
