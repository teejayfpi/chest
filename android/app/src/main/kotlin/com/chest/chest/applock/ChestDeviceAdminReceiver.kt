package com.chest.chest.applock

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Device administration receiver.
 *
 * Chest asks for the narrowest possible admin: the only policy it uses is
 * [android.app.admin.DevicePolicyManager.setApplicationHidden], which is what
 * turns a "freeze" into something the operating system enforces rather than
 * something Chest merely remembers. That call requires an active admin, so this
 * receiver exists mostly to be enabled.
 *
 * No password, camera, encryption or wipe policy is requested, so granting
 * Chest admin rights does not grant the ability to lock or erase the device.
 */
class ChestDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        Log.i(TAG, "device admin enabled")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        Log.i(TAG, "device admin disabled")
    }

    private companion object {
        const val TAG = "ChestDeviceAdmin"
    }
}
