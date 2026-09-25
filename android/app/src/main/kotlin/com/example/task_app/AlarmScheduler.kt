package com.example.task_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

data class AlarmScheduleResult(
    val armed: Boolean,
    val exact: Boolean,
    val exactAccess: Boolean,
    val error: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "armed" to armed,
        "exact" to exact,
        "exactAccess" to exactAccess,
        "error" to error
    )
}

object AlarmScheduler {
    const val EXTRA_REQUEST_CODE = "pylo_alarm_request_code"
    const val EXTRA_TASK_ID = "pylo_alarm_task_id"
    const val EXTRA_TASK_TITLE = "pylo_alarm_task_title"
    const val EXTRA_ALARM_TIME_MS = "pylo_alarm_time_ms"
    const val ACTION_ALARM = "com.example.task_app.ACTION_TASK_ALARM"
    const val ACTION_EXACT_ALARM_PERMISSION_CHANGED = "com.example.task_app.ACTION_EXACT_ALARM_PERMISSION_CHANGED"
    const val FLUTTER_PREFS = "FlutterSharedPreferences"
    const val PREF_SOUND_ID = "flutter.alarm_sound_id"
    const val PREF_CUSTOM_URI = "flutter.custom_alarm_uri"
    const val PREF_VIBRATE = "flutter.alarm_vibrate"
    const val PREF_SNOOZE_MIN = "flutter.alarm_snooze_minutes"

    private const val TAG = "PyloAlarmScheduler"
    private const val PREFS = "pylo_alarm_prefs"
    private const val KEY_PENDING = "pylo_pending_alarms"
    private const val PREF_TASK_NOTIFICATIONS = "flutter.notifications_enabled"

    fun schedule(
        context: Context,
        requestCode: Int,
        timeMs: Long,
        taskId: String,
        title: String
    ): AlarmScheduleResult {
        if (timeMs <= System.currentTimeMillis()) {
            return AlarmScheduleResult(false, false, canScheduleExact(context), "Alarm time is in the past")
        }
        if (!areTaskNotificationsEnabled(context)) {
            return AlarmScheduleResult(false, false, canScheduleExact(context), "Task notifications are disabled")
        }

        val exactAccess = canScheduleExact(context)
        return try {
            val pi = alarmPendingIntent(context, requestCode, timeMs, taskId, title)
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val exact = try {
                if (exactAccess) {
                    alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timeMs, pi)
                } else {
                    alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timeMs, pi)
                }
                exactAccess
            } catch (securityError: SecurityException) {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, timeMs, pi)
                false
            }
            savePending(context, requestCode, timeMs, taskId, title)
            Log.i(TAG, "Alarm armed task=$taskId requestCode=$requestCode exact=$exact exactAccess=$exactAccess")
            AlarmScheduleResult(true, exact, exactAccess)
        } catch (error: Exception) {
            Log.e(TAG, "Alarm scheduling failed task=$taskId requestCode=$requestCode", error)
            AlarmScheduleResult(false, false, exactAccess, error.message ?: error.javaClass.simpleName)
        }
    }

    fun cancel(context: Context, requestCode: Int) {
        try {
            val pendingIntent = alarmPendingIntent(context, requestCode, 0L, "", "")
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
        } catch (error: Exception) {
            Log.w(TAG, "Alarm cancellation failed requestCode=$requestCode", error)
        }
        removePending(context, requestCode)
    }

    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return try {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.canScheduleExactAlarms()
        } catch (error: Exception) {
            Log.w(TAG, "Exact alarm access check failed", error)
            false
        }
    }

    fun openExactAlarmSettings(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        try {
            context.startActivity(
                Intent(
                    android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    Uri.parse("package:${context.packageName}")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (error: Exception) {
            Log.w(TAG, "Unable to open exact alarm settings", error)
        }
    }

    fun shouldRing(context: Context, taskId: String, alarmTimeMs: Long): Boolean {
        if (!areTaskNotificationsEnabled(context)) return false
        return try {
            val databaseFile = context.getDatabasePath("taskflow.db")
            if (!databaseFile.exists()) return true
            SQLiteDatabase.openDatabase(
                databaseFile.absolutePath,
                null,
                SQLiteDatabase.OPEN_READONLY
            ).use { database ->
                database.rawQuery(
                    "SELECT isCompleted, isArchived, isDeleted, alarmEnabled, alarmTime FROM tasks WHERE id = ? LIMIT 1",
                    arrayOf(taskId)
                ).use { cursor ->
                    if (!cursor.moveToFirst()) return false
                    val active = cursor.getInt(0) == 0 &&
                        cursor.getInt(1) == 0 &&
                        cursor.getInt(2) == 0 &&
                        cursor.getInt(3) == 1 &&
                        cursor.getLong(4) == alarmTimeMs
                    active
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "Task eligibility check failed task=$taskId; allowing alarm", error)
            true
        }
    }

    private fun alarmPendingIntent(
        context: Context,
        requestCode: Int,
        timeMs: Long,
        taskId: String,
        title: String
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode,
        buildTriggerIntent(context, requestCode, timeMs, taskId, title),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    private fun buildTriggerIntent(
        context: Context,
        requestCode: Int,
        timeMs: Long,
        taskId: String,
        title: String
    ): Intent = Intent(context, AlarmReceiver::class.java).apply {
        action = ACTION_ALARM
        data = Uri.parse("pylo://task_alarm/$requestCode")
        putExtra(EXTRA_REQUEST_CODE, requestCode)
        putExtra(EXTRA_TASK_ID, taskId)
        putExtra(EXTRA_TASK_TITLE, title)
        putExtra(EXTRA_ALARM_TIME_MS, timeMs)
    }

    private fun areTaskNotificationsEnabled(context: Context): Boolean = try {
        val preferences = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        if (!preferences.contains(PREF_TASK_NOTIFICATIONS)) {
            true
        } else {
            preferences.getBoolean(PREF_TASK_NOTIFICATIONS, true)
        }
    } catch (error: Exception) {
        Log.w(TAG, "Task notification preference check failed", error)
        true
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    private fun savePending(
        context: Context,
        requestCode: Int,
        timeMs: Long,
        taskId: String,
        title: String
    ) {
        val alarms = parse(prefs(context).getString(KEY_PENDING, null))
        val cleaned = JSONArray()
        for (index in 0 until alarms.length()) {
            val alarm = alarms.optJSONObject(index) ?: continue
            if (alarm.optInt("rc") != requestCode && alarm.optLong("t") > System.currentTimeMillis()) {
                cleaned.put(alarm)
            }
        }
        cleaned.put(
            JSONObject()
                .put("rc", requestCode)
                .put("t", timeMs)
                .put("id", taskId)
                .put("title", title)
        )
        prefs(context).edit().putString(KEY_PENDING, cleaned.toString()).commit()
    }

    @Synchronized
    private fun removePending(context: Context, requestCode: Int) {
        val alarms = parse(prefs(context).getString(KEY_PENDING, null))
        val cleaned = JSONArray()
        for (index in 0 until alarms.length()) {
            val alarm = alarms.optJSONObject(index) ?: continue
            if (alarm.optInt("rc") != requestCode) cleaned.put(alarm)
        }
        prefs(context).edit().putString(KEY_PENDING, cleaned.toString()).commit()
    }

    @Synchronized
    fun rescheduleAll(context: Context): Int {
        if (!areTaskNotificationsEnabled(context)) {
            prefs(context).edit().remove(KEY_PENDING).commit()
            return 0
        }

        val alarms = parse(prefs(context).getString(KEY_PENDING, null))
        val kept = JSONArray()
        var armedCount = 0
        for (index in 0 until alarms.length()) {
            val alarm = alarms.optJSONObject(index) ?: continue
            val timeMs = alarm.optLong("t")
            val taskId = alarm.optString("id", "")
            if (timeMs <= System.currentTimeMillis() || taskId.isEmpty()) continue
            if (!shouldRing(context, taskId, timeMs)) continue
            val result = schedule(
                context,
                alarm.optInt("rc"),
                timeMs,
                taskId,
                alarm.optString("title", "Task")
            )
            if (result.armed) {
                kept.put(alarm)
                armedCount += 1
            }
        }
        prefs(context).edit().putString(KEY_PENDING, kept.toString()).commit()
        return armedCount
    }

    private fun parse(listJson: String?): JSONArray {
        if (listJson.isNullOrBlank()) return JSONArray()
        return try {
            JSONArray(listJson)
        } catch (_: Exception) {
            JSONArray()
        }
    }
}
