package com.example.task_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class AlarmBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        when (action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            AlarmScheduler.ACTION_EXACT_ALARM_PERMISSION_CHANGED -> {
                val count = AlarmScheduler.rescheduleAll(context)
                Log.i("PyloAlarmBootReceiver", "Re-armed $count alarms for action=$action")
            }
        }
    }
}
