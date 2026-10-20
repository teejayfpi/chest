package com.chest.chest.applock

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Device administration receiver.
 *
 * Chest asks for admin rights so it can be *provisioned* as device owner. The
 * hide operation itself (`setApplicationHidden`) is not available to a legacy
 * device admin — the platform rejects it with `SecurityException` on any app
 * targeting API 24 or above — so this receiver is a prerequisite for
 * provisioning rather than the thing that enforces a freeze.
 *
 * No password, camera, encryption or wipe policy is requested, so granting
 * Chest admin rights does not by itself grant the ability to lock or erase the
 * device. Provisioning Chest as device owner does grant that ability; the
 * freezer explains this before asking the user to run the command.
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
