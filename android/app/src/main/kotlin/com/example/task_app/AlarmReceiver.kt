package com.example.task_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AlarmScheduler.ACTION_ALARM) return

        val requestCode = intent.getIntExtra(AlarmScheduler.EXTRA_REQUEST_CODE, 0)
        val taskId = intent.getStringExtra(AlarmScheduler.EXTRA_TASK_ID).orEmpty()
        if (taskId.isEmpty()) return

        val title = intent.getStringExtra(AlarmScheduler.EXTRA_TASK_TITLE)
            ?.takeIf { it.isNotBlank() }
            ?: context.getString(R.string.app_name)
        val alarmTimeMs = intent.getLongExtra(
            AlarmScheduler.EXTRA_ALARM_TIME_MS,
            System.currentTimeMillis()
        )

        if (!AlarmScheduler.shouldRing(context, taskId, alarmTimeMs)) {
            AlarmScheduler.cancel(context, requestCode)
            Log.i("PyloAlarmReceiver", "Skipped inactive task=$taskId requestCode=$requestCode")
            return
        }

        val showIntent = Intent(context, AlarmActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            putExtra(AlarmScheduler.EXTRA_REQUEST_CODE, requestCode)
            putExtra(AlarmScheduler.EXTRA_TASK_ID, taskId)
            putExtra(AlarmScheduler.EXTRA_TASK_TITLE, title)
            putExtra(AlarmScheduler.EXTRA_ALARM_TIME_MS, alarmTimeMs)
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            requestCode,
            showIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "pylo_alarm_launch"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notificationManager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    "Task alarms",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                    setSound(null, null)
                    enableVibration(false)
                }
            )
        }
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText("Task alarm")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(contentIntent)
            .setFullScreenIntent(contentIntent, true)
            .setOngoing(true)
            .setAutoCancel(false)
            .build()
        notificationManager.notify(ALERT_NOTIFICATION_BASE + requestCode, notification)

        try {
            context.startActivity(showIntent)
        } catch (error: Exception) {
            Log.w("PyloAlarmReceiver", "Direct alarm launch failed; full-screen notification remains", error)
        }
    }

    companion object {
        const val ALERT_NOTIFICATION_BASE = 200000
    }
}
