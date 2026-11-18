package io.github.ccch1mneyyy.dsh_app.phone

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings

/**
 * One-shot reminders that outlive the engine: an inexact AlarmManager alarm plus the notification
 * channel this app already uses for `notify`.
 *
 * Inexact on purpose. `setExactAndAllowWhileIdle` needs SCHEDULE_EXACT_ALARM, which this app does
 * not request; `setAndAllowWhileIdle` needs no permission and may land a few minutes late under
 * Doze. The alarm lives in AlarmManager, not in the engine, so stopping the engine does not lose
 * it — a force-stop or a reboot does, and the tool result says so instead of promising delivery.
 */
internal object ReminderAlarm {
    internal const val EXTRA_TITLE = "io.github.ccch1mneyyy.dsh_app.reminder.title"
    internal const val EXTRA_TEXT = "io.github.ccch1mneyyy.dsh_app.reminder.text"

    /** Schedules one reminder at the absolute instant [atMs]. */
    fun schedule(context: Context, title: String, text: String, atMs: Long): SysResult {
        // l10n:keep agent tool result
        if (atMs <= System.currentTimeMillis()) return SysResult(false, "提醒时间已经过去，没有安排。")
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            // l10n:keep agent tool result
            ?: return SysResult(false, "这台设备没有通知服务，提醒没有安排。")
        if (!nm.areNotificationsEnabled()) {
            // l10n:keep agent tool result
            return SysResult(false, "DSH 没有通知权限，提醒发不出去。请用户在系统设置里允许 DSH 发通知。")
        }
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            // l10n:keep agent tool result
            ?: return SysResult(false, "这台设备没有闹钟服务，提醒没有安排。")
        val intent = Intent(context, ReminderReceiver::class.java)
            .putExtra(EXTRA_TITLE, title.take(100))
            .putExtra(EXTRA_TEXT, text.take(2000))
        // A distinct request code per reminder keeps two reminders from replacing each other's text.
        val request = atMs.xor(atMs ushr 32).toInt()
        val pending = PendingIntent.getBroadcast(
            context, request, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return try {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
            SysResult(true, "已安排提醒。")
        } catch (e: SecurityException) {
            // l10n:keep agent tool result
            SysResult(false, "系统拒绝了这次提醒安排（${e.message ?: "未知原因"}），没有安排。")
        }
    }

    /** Posts a reminder through the same channel as `notify`, so the person sees one channel. */
    fun post(context: Context, title: String, text: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val channel = SystemActions.CHANNEL_NOTIFY
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(channel, AppStrings.get(context, R.string.phone_reminder_channel),
                    NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(context)
        }
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        nm.notify(
            "dsh-reminder".hashCode(),
            builder
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }
}

/** Delivers one scheduled reminder. Not exported: only this app's own alarm reaches it. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra(ReminderAlarm.EXTRA_TITLE) ?: return
        ReminderAlarm.post(context, title, intent.getStringExtra(ReminderAlarm.EXTRA_TEXT).orEmpty())
    }
}
