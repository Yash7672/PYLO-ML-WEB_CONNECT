package com.example.task_app

import android.Manifest
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "pylo/focus"
    private val ALARM_CHANNEL = "pylo/alarm"
    private var isLockTaskActive = false
    private var pendingWidgetAction: String? = null
    private var pendingWidgetTaskId: String? = null
    private var pendingWidgetHabitId: String? = null

    private var phoneStateListener: Any? = null
    private var telephonyManager: TelephonyManager? = null
    private var exitedLockTaskForCall = false
    private var callActive = false
    private var flutterEngineRef: FlutterEngine? = null
    private var exactAlarmAccessInitialized = false
    private var hadExactAlarmAccess = false

    private val PHONE_STATE_PERMISSION_REQUEST = 1001

    // ── VoIP call detection via TelecomManager polling ─────────────────
    private var voipCheckHandler: Handler? = null
    private var voipCheckRunnable: Runnable? = null
    private val VOIP_CHECK_INTERVAL_MS = 1500L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngineRef = flutterEngine

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterLockTask" -> result.success(enterLockTask())
                    "exitLockTask" -> result.success(exitLockTask())
                    "isLockTaskActive" -> result.success(isLockTaskActive())
                    "setLockScreenFlags" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setLockScreenFlags(enabled)
                        result.success(true)
                    }
                    "setKeepScreenOn" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setKeepScreenOn(enabled)
                        result.success(true)
                    }
                    "requestPhoneStatePermission" -> {
                        result.success(requestPhoneStatePermission())
                    }
                    "getWidgetAction" -> {
                        result.success(mapOf(
                            "action" to pendingWidgetAction,
                            "task_id" to pendingWidgetTaskId,
                            "habit_id" to pendingWidgetHabitId,
                        ))
                    }
                    "clearWidgetAction" -> {
                        pendingWidgetAction = null
                        pendingWidgetTaskId = null
                        pendingWidgetHabitId = null
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALARM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleAlarm" -> {
                        val requestCode = call.argument<Int>("requestCode") ?: 0
                        val timeMs = call.argument<Long>("timeMs") ?: 0L
                        val taskId = call.argument<String>("taskId").orEmpty()
                        val title = call.argument<String>("title").orEmpty()
                        if (requestCode <= 0 || timeMs <= 0 || taskId.isEmpty()) {
                            result.error("bad_args", "Invalid alarm arguments", null)
                        } else {
                            result.success(
                                AlarmScheduler.schedule(
                                    this, requestCode, timeMs, taskId, title
                                ).toMap()
                            )
                        }
                    }
                    "cancelAlarm" -> {
                        val requestCode = call.argument<Int>("requestCode") ?: 0
                        AlarmScheduler.cancel(this, requestCode)
                        result.success(true)
                    }
                    "canScheduleExactAlarms" -> {
                        result.success(AlarmScheduler.canScheduleExact(this))
                    }
                    "openExactAlarmSettings" -> {
                        AlarmScheduler.openExactAlarmSettings(this)
                        result.success(true)
                    }
                    "canUseFullScreenIntent" -> {
                        result.success(canUseFullScreenIntent())
                    }
                    "openFullScreenIntentSettings" -> {
                        openFullScreenIntentSettings()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        handleWidgetIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleWidgetIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        val canScheduleExact = AlarmScheduler.canScheduleExact(this)
        if (exactAlarmAccessInitialized && !hadExactAlarmAccess && canScheduleExact) {
            sendBroadcast(
                Intent(AlarmScheduler.ACTION_EXACT_ALARM_PERMISSION_CHANGED)
                    .setPackage(packageName)
            )
        }
        hadExactAlarmAccess = canScheduleExact
        exactAlarmAccessInitialized = true
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return notificationManager.canUseFullScreenIntent()
    }

    private fun openFullScreenIntentSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            Intent(
                Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                android.net.Uri.parse("package:$packageName")
            )
        } else {
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:$packageName")
            )
        }
        startActivity(intent)
    }

    override fun onDestroy() {
        stopVoipCallDetection()
        stopPhoneStateListener()
        super.onDestroy()
    }

    private fun handleWidgetIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        when (action) {
            "WIDGET_OPEN_TASK" -> {
                pendingWidgetAction = "open_task"
                pendingWidgetTaskId = intent.getStringExtra("widget_task_id")
                pendingWidgetHabitId = null
            }
            "WIDGET_OPEN_HABITS" -> {
                pendingWidgetAction = "open_habits"
                pendingWidgetHabitId = intent.getStringExtra("widget_habit_id")
                pendingWidgetTaskId = null
            }
            "WIDGET_OPEN_DASHBOARD" -> {
                pendingWidgetAction = "open_dashboard"
                pendingWidgetTaskId = null
                pendingWidgetHabitId = null
            }
            "WIDGET_ADD_TASK" -> {
                pendingWidgetAction = "add_task"
                pendingWidgetTaskId = null
                pendingWidgetHabitId = null
            }
            "WIDGET_OPEN_FOCUS" -> {
                pendingWidgetAction = "open_focus"
                pendingWidgetTaskId = null
                pendingWidgetHabitId = null
            }
            "WIDGET_OPEN_CHECKLIST" -> {
                pendingWidgetAction = "open_checklist"
                pendingWidgetTaskId = null
                pendingWidgetHabitId = null
            }
            "WIDGET_OPEN_BIRTHDAYS" -> {
                pendingWidgetAction = "open_birthdays"
                pendingWidgetTaskId = null
                pendingWidgetHabitId = null
            }
        }
    }

    // ── Lock Task lifecycle ────────────────────────────────────────────

    private fun enterLockTask(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                startLockTask()
                isLockTaskActive = true

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    setShowWhenLocked(true)
                    setTurnScreenOn(true)
                } else {
                    @Suppress("DEPRECATION")
                    window.addFlags(
                        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    )
                }

                startPhoneStateListener()
                startVoipCallDetection()

                true
            } else {
                false
            }
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun exitLockTask(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                stopLockTask()
                isLockTaskActive = false

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    setShowWhenLocked(false)
                    setTurnScreenOn(false)
                } else {
                    @Suppress("DEPRECATION")
                    window.clearFlags(
                        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    )
                }

                stopVoipCallDetection()
                stopPhoneStateListener()

                true
            } else {
                false
            }
        } catch (_: Exception) {
            isLockTaskActive = false
            false
        }
    }

    private fun isLockTaskActive(): Boolean {
        return try {
            val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val systemReported = activityManager.isInLockTaskMode
                systemReported || isLockTaskActive
            } else {
                false
            }
        } catch (_: Exception) {
            isLockTaskActive
        }
    }

    private fun setLockScreenFlags(enabled: Boolean) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(enabled)
                setTurnScreenOn(enabled)
            } else {
                @Suppress("DEPRECATION")
                if (enabled) {
                    window.addFlags(
                        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    )
                } else {
                    window.clearFlags(
                        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    )
                }
            }
        } catch (_: Exception) {
        }
    }

    /// Keeps the screen fully on while a full-screen alarm is displayed so an
    /// active alarm can never let the display time out mid-ring.
    private fun setKeepScreenOn(enabled: Boolean) {
        try {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        } catch (_: Exception) {
        }
    }

    // ── Phone state listener (cellular calls) ─────────────────────────

    private fun requestPhoneStatePermission(): Boolean {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.READ_PHONE_STATE),
                PHONE_STATE_PERMISSION_REQUEST
            )
            return false
        }
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PHONE_STATE_PERMISSION_REQUEST) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startPhoneStateListener()
                startVoipCallDetection()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun startPhoneStateListener() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        stopPhoneStateListener()

        telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

        val listener = object : PhoneStateListener() {
            @Deprecated("Deprecated in Java")
            override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                handlePhoneCallState(state)
            }
        }
        telephonyManager?.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
        phoneStateListener = listener
    }

    private fun stopPhoneStateListener() {
        @Suppress("DEPRECATION")
        if (phoneStateListener != null && telephonyManager != null) {
            telephonyManager?.listen(phoneStateListener as PhoneStateListener, PhoneStateListener.LISTEN_NONE)
            phoneStateListener = null
        }
    }

    private fun handlePhoneCallState(state: Int) {
        when (state) {
            TelephonyManager.CALL_STATE_RINGING, TelephonyManager.CALL_STATE_OFFHOOK -> {
                if (isLockTaskActive && !exitedLockTaskForCall) {
                    exitedLockTaskForCall = true
                    callActive = true
                    temporarilyReleaseLockTask()
                }
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                if (exitedLockTaskForCall && !isAnyCallActive()) {
                    exitedLockTaskForCall = false
                    callActive = false
                    notifyFlutterCallState("call_ended")
                }
            }
        }
    }

    // ── VoIP call detection via TelecomManager polling ─────────────────
    // WhatsApp and other VoIP apps register calls with Android's Telecom
    // framework on API 23+. Polling TelecomManager.isInCall() detects
    // these calls and temporarily releases Lock Task so the system call
    // UI can appear.

    private fun startVoipCallDetection() {
        stopVoipCallDetection()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        voipCheckHandler = Handler(Looper.getMainLooper())
        voipCheckRunnable = object : Runnable {
            override fun run() {
                checkForVoipCall()
                voipCheckHandler?.postDelayed(this, VOIP_CHECK_INTERVAL_MS)
            }
        }
        voipCheckHandler?.postDelayed(voipCheckRunnable!!, VOIP_CHECK_INTERVAL_MS)
    }

    private fun stopVoipCallDetection() {
        voipCheckRunnable?.let { r -> voipCheckHandler?.removeCallbacks(r) }
        voipCheckRunnable = null
        voipCheckHandler = null
    }

    private fun checkForVoipCall() {
        if (!isLockTaskActive && !exitedLockTaskForCall) return

        try {
            val telecomManager = getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return

            @Suppress("DEPRECATION")
            val isInCall = telecomManager.isInCall

            if (isInCall) {
                if (!exitedLockTaskForCall) {
                    exitedLockTaskForCall = true
                    callActive = true
                    temporarilyReleaseLockTask()
                }
            } else if (exitedLockTaskForCall && !isAnyCallActive()) {
                exitedLockTaskForCall = false
                callActive = false
                notifyFlutterCallState("call_ended")
            }
        } catch (_: SecurityException) {
        } catch (_: Exception) {
        }
    }

    private fun isAnyCallActive(): Boolean {
        try {
            val telecomManager = getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            if (telecomManager != null) {
                @Suppress("DEPRECATION")
                if (telecomManager.isInCall) {
                    return true
                }
            }
        } catch (_: SecurityException) {
        } catch (_: Exception) {
        }

        try {
            @Suppress("DEPRECATION")
            val phoneState = telephonyManager?.callState ?: TelephonyManager.CALL_STATE_IDLE
            if (phoneState != TelephonyManager.CALL_STATE_IDLE) {
                return true
            }
        } catch (_: Exception) {
        }

        return false
    }

    // ── Lock Task release ────────────────────────────────────────────

    private fun temporarilyReleaseLockTask() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            } else {
                @Suppress("DEPRECATION")
                window.clearFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    stopLockTask()
                }
            } catch (_: Exception) {
            }

            notifyFlutterCallState("call_active")
        } catch (_: Exception) {
        }
    }

    private fun notifyFlutterCallState(state: String) {
        try {
            flutterEngineRef?.let { engine ->
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod("onCallStateChanged", state)
            }
        } catch (_: Exception) {
        }
    }
}
