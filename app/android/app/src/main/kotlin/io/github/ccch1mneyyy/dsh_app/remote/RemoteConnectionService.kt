package io.github.ccch1mneyyy.dsh_app.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.content.pm.ServiceInfo
import io.github.ccch1mneyyy.dsh_app.MainActivity

/** Keeps the Flutter process and remote relay/WebRTC sockets resident while connected. */
class RemoteConnectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        ensureChannel()
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("DSH Remote")
            .setContentText("远程主机连接保持中")
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(ID, notification)
        return START_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "DSH Remote", NotificationManager.IMPORTANCE_LOW))
    }

    companion object {
        const val ACTION_START = "io.github.ccch1mneyyy.dsh_app.remote.START"
        const val ACTION_STOP = "io.github.ccch1mneyyy.dsh_app.remote.STOP"
        private const val CHANNEL = "dsh_remote_connection"
        private const val ID = 4207
    }
}
