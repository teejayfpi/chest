package com.chest.chest.files

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Picks files and reads them without leaving a plaintext copy behind.
 *
 * This exists because the general-purpose picker plugin does two things a vault
 * cannot accept:
 *
 *  - It **copies every picked file into the app's own cache** as plaintext
 *    before handing the bytes to Dart, so a "sealed" photo also exists
 *    unencrypted in Chest's data directory. Nothing else cleans that up.
 *  - It **never asks for write access**, so the original cannot be removed
 *    afterwards. The user's photo stays in their gallery and the app cannot
 *    make it go away.
 *
 * Both are fixed by driving the picker directly. [buildPickIntent] requests the
 * read *and* write grant, [readBytes] streams the provider's bytes into memory
 * with no intermediate file, and [ChestFileSealer] deletes the original once
 * the vault holds a sealed copy.
 *
 * The file is read in memory rather than through a temporary file on purpose:
 * a cache copy would be exactly the leak this class exists to avoid.
 */
object ChestFilePicker {

    private const val TAG = "ChestFilePicker"

    /** Provider did not report a size, so the caller must read to find out. */
    const val UNKNOWN_SIZE = -1L

    /**
     * An `ACTION_OPEN_DOCUMENT` picker that grants read and write on the
     * chosen files.
     *
     * `ACTION_OPEN_DOCUMENT` rather than `ACTION_GET_CONTENT`: only the former
     * can return a URI the app may later delete and may hold across restarts.
     * `FLAG_GRANT_WRITE_URI_PERMISSION` is the flag that makes hiding possible
     * at all; without it the provider rejects the delete.
     */
    fun buildPickIntent(): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    }

    /**
     * Holds onto the grant so the delete later in the same session is allowed,
     * and so a grant left over from a crash can still be released.
     *
     * Failure is not fatal: a transient grant still covers the delete that
     * happens moments after the pick.
     */
    fun takeGrant(context: Context, uri: Uri) {
        try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            Log.d(TAG, "no persistable grant for $uri; continuing with the transient one")
        }
    }

    /** Drops the grant once the original is gone, so Chest keeps no lasting access. */
    fun releaseGrant(context: Context, uri: Uri) {
        runCatching {
            context.contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
    }

    /** Name, size and MIME type, so the UI can label the file before sealing. */
    fun describe(context: Context, uri: Uri): Map<String, Any> {
        var name: String? = null
        var size = UNKNOWN_SIZE
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    name = cursor.getString(nameIndex)
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    size = cursor.getLong(sizeIndex)
                }
            }
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: uri.lastPathSegment ?: "file"),
            "size" to size,
            "mimeType" to (context.contentResolver.getType(uri) ?: "application/octet-stream"),
        )
    }

    /**
     * Reads the whole file into memory.
     *
     * [maxBytes] is enforced while reading, not after, so an unexpectedly large
     * file cannot exhaust the heap before the caller gets a chance to refuse
     * it. Returns null and sets [error] instead of throwing.
     */
    fun readBytes(context: Context, uri: Uri, maxBytes: Long): ByteArray? {
        error = null
        return try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArrayOutputStream()
                val chunk = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(chunk)
                    if (read <= 0) break
                    total += read
                    if (total > maxBytes) {
                        error = "file_too_large"
                        return null
                    }
                    buffer.write(chunk, 0, read)
                }
                buffer.toByteArray()
            } ?: run {
                error = "unreadable"
                null
            }
        } catch (e: SecurityException) {
            error = "no_read_permission"
            null
        } catch (e: Exception) {
            Log.w(TAG, "could not read $uri", e)
            error = e.message ?: "read_failed"
            null
        }
    }

    /** Why the last [readBytes] returned null, or null when it succeeded. */
    @Volatile
    var error: String? = null
        private set

    /** Every URI the picker returned, from either the single or the multi form. */
    fun urisFrom(data: Intent): List<Uri> {
        val clip = data.clipData
        if (clip != null) {
            return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
        }
        val single = data.data ?: return emptyList()
        return listOf(single)
    }
}
