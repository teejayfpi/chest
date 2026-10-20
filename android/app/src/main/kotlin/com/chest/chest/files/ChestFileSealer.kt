package com.chest.chest.files

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log

/**
 * Result of trying to remove a source file once its contents are sealed.
 *
 * `removed` means the original is genuinely gone. When it is false the caller
 * must say so: the bytes are in the vault, but the user's original is still on
 * the device and still visible to other apps.
 */
data class HideOutcome(
    val removed: Boolean,
    val reason: String?,
)

/**
 * Deletes the original of a file that has just been sealed into the vault.
 *
 * This is what makes "hide" mean hidden. Sealing alone only *copies* bytes: the
 * photo the user picked is still sitting in `DCIM/`, still visible in their
 * gallery, and still readable by every other app. Removing that original is the
 * step that actually takes it out of view.
 *
 * Two deletion routes are needed because Android hands back two different kinds
 * of handle depending on where the file came from:
 *
 *  - **`content://` URIs** from the Storage Access Framework, which is what the
 *    picker returns on Android 10+. These go through
 *    [DocumentsContract.deleteDocument], which needs the write grant that
 *    `AndroidSAFAccessMode.readWrite` asks the picker for. No storage
 *    permission is involved and none is requested; the grant covers only the
 *    file the user chose.
 *  - **Plain filesystem paths** from a `file://` result, deleted directly.
 *
 * The MediaStore is deliberately not used. Deleting through it would need
 * `WRITE_EXTERNAL_STORAGE`, which this app does not request, and on Android 11+
 * it cannot remove media owned by another app without a per-file consent
 * dialog. A scoped SAF grant does the same job with no standing permission,
 * which is the better trade for a vault.
 */
object ChestFileSealer {

    private const val TAG = "ChestFileSealer"

    /**
     * Attempts to delete the file behind [uri].
     *
     * Never throws. A failure is returned as an outcome so the caller can tell
     * the user the original is still on the device; silently leaving a copy
     * behind while the UI reports success would be the worst behaviour here.
     */
    fun deleteSource(context: Context, uri: Uri): HideOutcome = try {
        when (uri.scheme?.lowercase()) {
            ContentResolver.SCHEME_CONTENT -> deleteContent(context, uri)
            ContentResolver.SCHEME_FILE -> deleteFile(uri)
            else -> HideOutcome(false, "unsupported URI scheme '${uri.scheme}'")
        }
    } catch (e: Exception) {
        Log.w(TAG, "could not remove source $uri", e)
        HideOutcome(false, e.message ?: "delete failed")
    }

    private fun deleteContent(context: Context, uri: Uri): HideOutcome = try {
        val deleted = DocumentsContract.deleteDocument(context.contentResolver, uri)
        if (deleted) {
            HideOutcome(true, null)
        } else {
            HideOutcome(false, "the file provider refused the delete")
        }
    } catch (e: SecurityException) {
        // The picker granted read but not write, so the original survives.
        HideOutcome(false, "no write permission for this file")
    } catch (e: IllegalArgumentException) {
        // Not a document URI, so there is no document to delete.
        HideOutcome(false, "this file cannot be removed automatically")
    }

    private fun deleteFile(uri: Uri): HideOutcome {
        val path = uri.path ?: return HideOutcome(false, "no path in file URI")
        val file = java.io.File(path)
        // Already gone is the outcome the caller wanted.
        if (!file.exists()) return HideOutcome(true, null)
        return if (runCatching { file.delete() }.getOrDefault(false)) {
            HideOutcome(true, null)
        } else {
            HideOutcome(false, "the file could not be deleted")
        }
    }

    /**
     * A chooser for handing a sealed file to another app.
     *
     * Chest keeps no plaintext on disk, so the caller writes the decrypted bytes
     * to a cache file, passes it here, and deletes it once the chooser returns.
     * The URI is published through a FileProvider, so no storage permission is
     * needed for the receiving app to read it.
     */
    fun shareIntent(context: Context, cacheFile: java.io.File, mimeType: String, title: String): Intent {
        val uri = androidx.core.content.FileProvider.getUriForFile(
            context,
            "${context.packageName}.chest.files",
            cacheFile,
        )
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return Intent.createChooser(send, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /**
     * WhatsApp's conversation with [phone], via a `wa.me` deep link.
     *
     * A deep link rather than an `https://` web fallback: WhatsApp handles it
     * directly, so Chest never touches the network and needs no INTERNET
     * permission. The caller launches the returned intent.
     */
    fun whatsappIntent(phone: String): Intent {
        val digits = phone.filter { it.isDigit() }
        return Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/$digits")).apply {
            setPackage("com.whatsapp")
        }
    }
}
