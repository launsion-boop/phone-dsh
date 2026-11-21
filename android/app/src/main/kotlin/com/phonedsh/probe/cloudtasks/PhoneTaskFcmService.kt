// SPDX-License-Identifier: MIT
package com.phonedsh.probe.cloudtasks

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.phonedsh.cloudtasks.CloudTaskWire
import com.phonedsh.probe.HostWakeScheduler

/** FCM transports only a wake hint. The existing Tono cloud pull supplies the task. */
class PhoneTaskFcmService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        CloudTaskCenter.get(applicationContext).pushTokenRotated(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (message.notification != null || !CloudTaskWire.isTaskPush(message.data)) return
        if (CloudTaskCenter.get(applicationContext).isEnabled) {
            HostWakeScheduler.get(applicationContext).onCloudPush()
        }
    }
}

/** Empty Firebase resources leave other installations on the normal native pull path. */
internal fun requestFcmToken(context: Context, accept: (String) -> Unit) {
    if (FirebaseApp.getApps(context).isEmpty()) return
    FirebaseMessaging.getInstance().token.addOnSuccessListener { token -> accept(token) }
}
