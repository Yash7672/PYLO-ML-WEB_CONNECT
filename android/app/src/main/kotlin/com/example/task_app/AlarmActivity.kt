package com.example.task_app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The actual "ringing" surface for a PYLO task alarm.
 *
 * Started directly by [AlarmReceiver] when AlarmManager fires an exact alarm
 * — NOT by tapping a notification. It owns audio playback and vibration for
 * the whole ring, shows a silent ongoing notification as a fallback indicator
 * (its tap just brings this activity back), and offers Snooze + Slide-to-stop.
 *
 * Ring behaviour is resolved at ring time from the shared_preferences plugin
 * store (global settings): sound id / custom uri / vibration / snooze minutes.
 */
class AlarmActivity : Activity() {

    private companion object {
        const val CHANNEL_RINGING = "pylo_alarm_ringing"
        const val NOTIFICATION_ID_PREFIX = 452100
        const val FLUTTER_PREFS = "FlutterSharedPreferences"
        const val MAX_AUDIO_RESTARTS = 3
    }

    private var mediaPlayer: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var isRinging = false
    private var dismissed = false

    /// Count of consecutive audio rebuilds within one ring session; reset on
    /// each (re)start of ringing so a recovered player can ring normally.
    private var audioRestartAttempts = 0

    private var requestCode = 0
    private var taskId = ""
    private var taskTitle = "Task"

    private val tickHandler = Handler(Looper.getMainLooper())
    private val tickRunnable = object : Runnable {
        override fun run() {
            updateClock()
            tickHandler.postDelayed(this, 1000L)
        }
    }

    private val prefs: SharedPreferences?
        get() {
            return try {
                getSharedPreferences(FLUTTER_PREFS, MODE_PRIVATE)
            } catch (_: Exception) {
                null
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readExtras()
        clearLaunchNotification()
        configureWindow()
        createRingingChannel()
        setContentView(R.layout.activity_alarm)
        bindUi()
        startRinging()
        tickHandler.post(tickRunnable)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readExtras()
        if (!isRinging) {
            startRinging()
        } else {
            startRingingAudioOnly()
        }
    }

    private fun readExtras() {
        val i = intent
        requestCode = i.getIntExtra(AlarmScheduler.EXTRA_REQUEST_CODE, 0)
        taskId = i.getStringExtra(AlarmScheduler.EXTRA_TASK_ID).orEmpty()
        taskTitle = i.getStringExtra(AlarmScheduler.EXTRA_TASK_TITLE)
            ?: getString(R.string.app_name)
    }

    private fun configureWindow() {
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
    }

    private fun createRingingChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_RINGING,
                getString(R.string.pylo_alarm_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.pylo_alarm_channel_desc)
                setSound(null, null)
                enableVibration(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun bindUi() {
        findViewById<TextView>(R.id.alarm_task_title)?.text = taskTitle
        findViewById<Button>(R.id.btn_snooze)?.setOnClickListener { snooze() }
        findViewById<SlideToStopView>(R.id.slide_stop)?.setOnSlideStopListener {
            stopRing()
        }
    }

    private fun startRinging() {
        publishRingingNotification()
        startRingingAudioOnly()
    }

    private fun startRingingAudioOnly() {
        if (dismissed) return
        // Reset the rebuild cap on every (re)start of ringing (fresh intent or
        // already-ringing update) so recovered sessions can ring normally.
        audioRestartAttempts = 0
        startAudio()
        startVibration()
        isRinging = true
    }

    private fun startAudio() {
        stopAudio()
        val soundId = prefs?.getString(AlarmScheduler.PREF_SOUND_ID, null)
        try {
            var player = if (soundId == PyloAlarmSoundId.CUSTOM) {
                buildCustomPlayer()
            } else {
                buildRawPlayer(resolveRawRes(soundId))
            }
            if (player == null) {
                player = buildRawPlayer(R.raw.alarm_classic)
            }
            player?.let {
                if (++audioRestartAttempts > MAX_AUDIO_RESTARTS) {
                    // Repeated rebuild failures (corrupt file / persistent OEM
                    // error) mean this loop will never ring — stop burning CPU
                    // instead of restarting audio on an infinite error loop.
                    mediaPlayer = null
                    return
                }
                mediaPlayer = it
                it.setOnErrorListener { _, _, _ ->
                    // Missing/corrupt custom file or an OEM loop bug: rebuild on
                    // the main thread instead of ringing in silence. Capped so
                    // a persistent error cannot spin startAudio forever.
                    Handler(Looper.getMainLooper()).post { startAudio() }
                    true
                }
                // isLooping = true, so a REAL end-of-stream never happens for
                // well-formed tracks. Listening for onCompletion and restarting
                // is unnecessary and, on some OEM ROMs, both callbacks can fire
                // for one failure — multiplying rebuilds. Completion relies on
                // startRinging()/stopRing() instead.
                it.isLooping = true
                it.start()
            }
        } catch (_: Exception) {
            mediaPlayer = null
        }
    }

    private fun buildRawPlayer(resId: Int): MediaPlayer? {
        return try {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(
                    this@AlarmActivity,
                    Uri.parse("android.resource://$packageName/$resId")
                )
                prepare()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun buildCustomPlayer(): MediaPlayer? {
        val customUri = prefs?.getString(AlarmScheduler.PREF_CUSTOM_URI, null)
            ?: return null
        val file = customFileFromUri(customUri)
        if (file == null || !file.exists()) return null
        return try {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                setDataSource(file.absolutePath)
                prepare()
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Maps a `content://com.example.task_app.fileProvider/files/alarms/X`
     *  URI onto `filesDir/alarms/X` (see res/xml/file_paths.xml). */
    private fun customFileFromUri(uri: String): File? {
        return try {
            val path = Uri.parse(uri).path ?: return null
            val segments = path.split('/').filter { it.isNotEmpty() }
            if (segments.isEmpty() || segments[0] != "files") return null
            var base = filesDir
            var i = 1
            while (i < segments.size - 1) {
                base = File(base, segments[i] ?: break)
                i++
            }
            File(base, segments.last())
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveRawRes(soundId: String?): Int {
        return when (soundId) {
            PyloAlarmSoundId.MARIMBA -> R.raw.alarm_marimba
            PyloAlarmSoundId.GENTLE -> R.raw.alarm_gentle
            PyloAlarmSoundId.DIGITAL -> R.raw.alarm_digital
            PyloAlarmSoundId.URGENT -> R.raw.alarm_urgent
            PyloAlarmSoundId.CLASSIC -> R.raw.alarm_classic
            else -> R.raw.alarm_classic
        }
    }

    private fun stopAudio() {
        try {
            mediaPlayer?.setOnCompletionListener(null)
            mediaPlayer?.setOnErrorListener(null)
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {
        }
        mediaPlayer = null
    }

    private fun startVibration() {
        val vibrate = prefs?.getBoolean(AlarmScheduler.PREF_VIBRATE, true) ?: true
        if (!vibrate) return
        try {
            @Suppress("DEPRECATION")
            vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager)
                    .defaultVibrator
            } else {
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(
                    VibrationEffect.createWaveform(longArrayOf(0, 700, 400), 0)
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(longArrayOf(0, 700, 400), 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopVibration() {
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
    }

    private fun publishRingingNotification() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val showIntent = Intent(this, AlarmActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
                putExtra(AlarmScheduler.EXTRA_REQUEST_CODE, requestCode)
                putExtra(AlarmScheduler.EXTRA_TASK_ID, taskId)
                putExtra(AlarmScheduler.EXTRA_TASK_TITLE, taskTitle)
            }
            val showPi = PendingIntent.getActivity(
                this,
                requestCode,
                showIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_RINGING)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            builder.setContentTitle(getString(R.string.pylo_alarm_notif_title))
                .setContentText(taskTitle)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setShowWhen(false)
                .setContentIntent(showPi)
                .setAutoCancel(false)
                .setCategory(Notification.CATEGORY_ALARM)
                .setPriority(Notification.PRIORITY_HIGH)
                .setFullScreenIntent(showPi, true)

            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                builder.build()
            } else {
                @Suppress("DEPRECATION")
                builder.build()
            }
            nm.notify(NOTIFICATION_ID_PREFIX + requestCode, notification)
        } catch (_: Exception) {
        }
    }

    private fun clearRingingNotification() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTIFICATION_ID_PREFIX + requestCode)
        } catch (_: Exception) {
        }
    }

    private fun clearLaunchNotification() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(AlarmReceiver.ALERT_NOTIFICATION_BASE + requestCode)
        } catch (_: Exception) {
        }
    }

    private fun snooze() {
        if (dismissed) return
        val minutes = prefs?.getInt(AlarmScheduler.PREF_SNOOZE_MIN, 5) ?: 5
        if (minutes <= 0) {
            stopRing()
            return
        }
        val at = System.currentTimeMillis() + minutes * 60_000L
        val result = AlarmScheduler.schedule(
            this, requestCode, at, taskId, taskTitle
        )
        if (!result.armed) {
            Log.e("PyloAlarmActivity", "Snooze was not armed for task=$taskId: ${result.error}")
            return
        }
        stopRing()
    }

    private fun stopRing() {
        if (dismissed) return
        dismissed = true
        tickHandler.removeCallbacks(tickRunnable)
        stopAudio()
        stopVibration()
        clearRingingNotification()
        finishAndRemoveTask()
    }

    private fun updateClock() {
        val now = Date()
        findViewById<TextView>(R.id.alarm_time)?.text =
            SimpleDateFormat("HH:mm", Locale.getDefault()).format(now)
        findViewById<TextView>(R.id.alarm_date)?.text =
            SimpleDateFormat("EEEE, d MMMM", Locale.getDefault()).format(now)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Sliding to stop is the only way out while ringing.
    }

    override fun onDestroy() {
        tickHandler.removeCallbacks(tickRunnable)
        stopAudio()
        stopVibration()
        super.onDestroy()
    }
}

/** Sound-id string constants shared with the Flutter PyloAlarmSound enum. */
object PyloAlarmSoundId {
    const val CLASSIC = "classic"
    const val MARIMBA = "marimba"
    const val GENTLE = "gentle"
    const val DIGITAL = "digital"
    const val URGENT = "urgent"
    const val CUSTOM = "custom"
}