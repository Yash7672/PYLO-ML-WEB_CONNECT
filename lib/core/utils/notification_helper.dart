import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import 'alarm_sound_service.dart';
import '../services/alarm_channel.dart';

/// Notification ID namespace offsets to prevent hash collisions.
/// Tasks use `id.hashCode`, birthdays use `id.hashCode + _birthdayOffset`.
/// This ensures task "abc" and birthday "abc-0" can never share an ID.
class NotificationId {
  static const int birthdayOffset = 500000000;

  /// Deterministic ID for a task reminder based on its offset in minutes.
  /// Using the offset instead of list index ensures that editing a task's
  /// reminder list never causes different reminders to collide.
  static int taskReminder(String taskId, int reminderMinutes) {
    return (taskId.hashCode + reminderMinutes) & 0x7FFFFFFF;
  }

  /// Deterministic ID for a task alarm.  Uses a large offset so it can
  /// never collide with any reminder minute value (max 1440).
  static int taskAlarm(String taskId) {
    return (taskId.hashCode + 999999) & 0x7FFFFFFF;
  }

  /// Returns all possible reminder notification IDs for a task across the
  /// full minute range 0–1440.  Used by cancelAllForTask to guarantee no
  /// stale reminders leak when the user adds custom minute offsets.
  static List<int> allReminderIds(String taskId) {
    // The range 0–1440 covers every minute of the day.  Using a fixed range
    // ensures that any user-configured offset (including non-standard values
    // like 3 or 7 minutes) is always cancelled.
    return List<int>.generate(1441, (i) => (taskId.hashCode + i) & 0x7FFFFFFF);
  }
}

/// The payload routed back into the app when an alarm fires.  A full-screen
/// alarm launches the activity with the notification's payload, so decoding
/// it here is how we know WHICH task woke the user and can show its screen.
class AlarmInfo {
  const AlarmInfo({
    required this.taskId,
    required this.taskTitle,
    required this.alarmTime,
    this.soundId,
    this.customUri,
  });

  final String taskId;
  final String taskTitle;
  final DateTime alarmTime;

  /// Per-task alarm sound override (`classic` … `custom`), or null to use the
  /// global Settings sound.  Embedded in the payload so the alarm screen can
  /// ring the right music for the right task even on a cold start.
  final String? soundId;

  /// Per-task custom sound content URI (used only when [soundId] == 'custom').
  final String? customUri;

  /// Stable identity used to de-duplicate alarm open events.
  String get key => '$taskId:${alarmTime.millisecondsSinceEpoch}';
}

class AlarmPayload {
  static const String scheme = 'pylo:alarm';

  /// Encodes the alarm into the notification payload string.
  /// Format: `pylo:alarm|<taskId>|<taskTitle>|<epochMs>|<soundId>|<customUri>`.
  /// The trailing sound fields are optional and empty when the task uses the
  /// global Settings sound, keeping older 4-part payloads decodable.
  static String encode({
    required String taskId,
    required String taskTitle,
    required DateTime alarmTime,
    String? soundId,
    String? customUri,
  }) {
    return '$scheme|${_encodePart(taskId)}|${_encodePart(taskTitle)}|'
        '${alarmTime.millisecondsSinceEpoch}'
        '|${_encodePart(soundId ?? '')}|${_encodePart(customUri ?? '')}';
  }

  /// Decodes a notification payload.  Returns null when the payload is not
  /// (or is no longer) a valid alarm payload.
  static AlarmInfo? decode(String? payload) {
    if (payload == null) return null;
    final parts = payload.split('|');
    if (parts.length < 4 || parts[0] != scheme) return null;
    final ms = int.tryParse(parts[3]);
    if (ms == null) return null;
    return AlarmInfo(
      taskId: _decodePart(parts[1]),
      taskTitle: _decodePart(parts[2]),
      alarmTime: DateTime.fromMillisecondsSinceEpoch(ms),
      soundId: parts.length > 4 && parts[4].isNotEmpty
          ? _decodePart(parts[4])
          : null,
      customUri: parts.length > 5 && parts[5].isNotEmpty
          ? _decodePart(parts[5])
          : null,
    );
  }

  static String _encodePart(String value) =>
      value.replaceAll('%', '%25').replaceAll('|', '%7C');
  static String _decodePart(String value) =>
      value.replaceAll('%7C', '|').replaceAll('%25', '%');
}

/// Built-in alarm sounds bundled as Android raw resources in
/// `res/raw/`.  `custom` uses a user-picked audio file instead.
enum PyloAlarmSound {
  classic('Classic', 'alarm_classic'),
  marimba('Marimba', 'alarm_marimba'),
  gentle('Gentle', 'alarm_gentle'),
  digital('Digital', 'alarm_digital'),
  urgent('Urgent', 'alarm_urgent'),
  custom('Custom', null);

  const PyloAlarmSound(this.label, this.rawName);

  /// Human-readable name shown in Settings.
  final String label;

  /// Raw resource name in res/raw (null for [PyloAlarmSound.custom]).
  final String? rawName;

  static PyloAlarmSound fromId(String? id) {
    return PyloAlarmSound.values.firstWhere(
      (sound) => sound.name == id,
      orElse: () => PyloAlarmSound.classic,
    );
  }
}

/// Everything that shapes the alarm's behaviour.  The configured sound is only
/// ever *played* by the in-app audioplayers engine (see AlarmScreen and
/// AlarmSoundService) — the OS notification that triggers the alarm is SILENT
/// because Android cannot open an app-private content:// sound while the app
/// process is closed and instead plays the default notification tone.
class AlarmChannelConfig {
  const AlarmChannelConfig({
    this.sound = PyloAlarmSound.classic,
    this.customUri,
    this.vibrate = true,
  });

  final PyloAlarmSound sound;

  /// `content://com.example.task_app.fileProvider/alarms/<file>` URI used
  /// when [sound] is [PyloAlarmSound.custom].
  final String? customUri;

  final bool vibrate;

  AlarmChannelConfig copyWith({
    PyloAlarmSound? sound,
    String? customUri,
    bool? vibrate,
  }) {
    return AlarmChannelConfig(
      sound: sound ?? this.sound,
      customUri: customUri ?? this.customUri,
      vibrate: vibrate ?? this.vibrate,
    );
  }

  static AlarmChannelConfig fromPrefs({
    required String? soundId,
    required String? customUri,
    required bool? vibrate,
  }) {
    return AlarmChannelConfig(
      sound: PyloAlarmSound.fromId(soundId),
      customUri: customUri,
      vibrate: vibrate ?? true,
    );
  }
}

class NotificationHelper {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static Future<void>? _initFuture;

  /// Upper bound on how many platform notifications one task may own. Must be
  /// identical between the scheduling loop and cancelAllForTask so a
  /// notification can never be scheduled that no cancel path can reach.
  static const int maxReminders = 12;

  /// Well-known reminder minute offsets used for deterministic cancel.
  static const List<int> knownReminderOffsets = [
    1,
    5,
    10,
    15,
    30,
    60,
    120,
    180,
    1440,
  ];

  /// SharedPreferences key remembering the last alarm already surfaced to the
  /// UI, so a cold start from an already-handled legacy alarm never re-opens
  /// (and re-rings) the same alarm a second time.
  static const String _keyLastHandledAlarm = 'pylo_last_handled_alarm';

  static const AndroidNotificationDetails _androidDetails =
      AndroidNotificationDetails(
    'taskflow_channel',
    'TaskFlow Notifications',
    channelDescription: 'Reminders for your tasks',
    importance: Importance.high,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    icon: '@mipmap/launcher_icon',
  );

  static const AndroidNotificationDetails _birthdayDetails =
      AndroidNotificationDetails(
    'birthday_channel',
    'Birthday Reminders',
    channelDescription: 'Reminders for upcoming birthdays',
    importance: Importance.max,
    priority: Priority.high,
    playSound: true,
    enableVibration: true,
    icon: '@mipmap/launcher_icon',
  );

  static const AndroidNotificationDetails _focusDetails =
      AndroidNotificationDetails(
    'focus_channel',
    'Focus Mode',
    channelDescription: 'Focus session notifications',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    ongoing: true,
    onlyAlertOnce: true,
    icon: '@mipmap/launcher_icon',
  );

  /// Fired every time an alarm fires through the LEGACY notification path
  /// (a full-screen intent that brought the app forward). Listeners (e.g.
  /// main.dart) present the in-app AlarmScreen. Modern task alarms ring
  /// natively (AlarmActivity) and never reach this stream.
  static final StreamController<AlarmInfo> _alarmController =
      StreamController<AlarmInfo>.broadcast();

  static Stream<AlarmInfo> get alarmEvents => _alarmController.stream;

  static AlarmInfo? _lastEmitted;
  static Timer? _dedupeResetTimer;

  /// Used by the AlarmScreen to suppress duplicate pushes while an alarm is
  /// already on screen.
  static bool isAlarmOpen = false;

  /// Ensure the notification plugin is initialized exactly once.
  /// Safe to call from any context; idempotent and race-free: concurrent first
  /// callers share a single in-flight init future instead of double-initializing.
  static Future<void> ensureInitialized() => init();

  static Future<void> init() async {
    if (kIsWeb) {
      return;
    }
    if (_initialized) return;
    final inFlight = _initFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final run = _doInit();
    _initFuture = run;
    try {
      await run;
    } finally {
      // Cleared on both success and failure so a failed attempt can retry on
      // the next call while concurrent callers awaited this shared future.
      _initFuture = null;
    }
  }

  static Future<void> _doInit() async {
    if (_initialized) return;

    try {
      final timezoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezoneInfo.identifier));
    } catch (e) {
      debugPrint('Timezone init failed: $e');
    }

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const InitializationSettings settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    _initialized = true;

    final androidImpl = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
  }

  /// Android 12+: opens the system "Alarms & reminders" screen so the user can
  /// grant SCHEDULE_EXACT_ALARM access.
  ///
  /// Deliberately NOT called from [init]: dropping every user straight into a
  /// system settings screen on first launch (with no context for why) is
  /// hostile UX and reads badly in Play review. Callers request it at a
  /// contextual moment instead — when the user turns task reminders on, or
  /// saves a task that actually carries a reminder or alarm.
  ///
  /// Nothing breaks when it is never granted: the native scheduler falls back
  /// to inexact alarms, so reminders still fire (possibly a little late)
  /// rather than silently disappearing.
  static Future<bool> requestExactAlarmAccess() async {
    if (kIsWeb) return true;
    try {
      await ensureInitialized();
      final androidImpl = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestExactAlarmsPermission();
      final granted = await AlarmChannel.canScheduleExactAlarms();
      debugPrint(
          'Exact alarm access granted=$granted timezone=${tz.local.name}');
      return granted;
    } catch (e) {
      debugPrint('Exact alarm access request failed: $e');
      return false;
    }
  }

  static Future<bool> notificationsAllowed() async {
    if (kIsWeb) return true;
    try {
      await ensureInitialized();
      final androidImpl = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await androidImpl?.areNotificationsEnabled() ?? true;
    } catch (e) {
      debugPrint('Notification permission check failed: $e');
      return true;
    }
  }

  /// Decodes a notification response (warm start: the alarm's full-screen
  /// intent brought the app forward) and surfaces the alarm to the UI.
  static void _onNotificationResponse(NotificationResponse response) {
    final alarm = AlarmPayload.decode(response.payload);
    if (alarm != null) _emitAlarm(alarm);
  }

  static void _emitAlarm(AlarmInfo alarm) {
    // Guard against duplicate deliveries for the same alarm (the full-screen
    // intent and a user tap can both reach the callback in quick succession).
    final last = _lastEmitted;
    if (last != null &&
        last.taskId == alarm.taskId &&
        alarm.alarmTime.difference(last.alarmTime).inSeconds.abs() <= 2) {
      return;
    }
    _lastEmitted = alarm;
    _dedupeResetTimer?.cancel();
    _dedupeResetTimer =
        Timer(const Duration(seconds: 5), () => _lastEmitted = null);
    unawaited(_markAlarmHandled(alarm));
    if (!isAlarmOpen) {
      _alarmController.add(alarm);
    }
  }

  /// Cold-start path: the OS launched the app directly from an alarm's
  /// full-screen intent.  Returns the alarm to present (skipping one that was
  /// already surfaced while the app was alive).
  static Future<AlarmInfo?> pendingLaunchAlarm() async {
    if (kIsWeb) return null;
    try {
      final details = await _notifications.getNotificationAppLaunchDetails();
      final alarm = AlarmPayload.decode(details?.notificationResponse?.payload);
      if (alarm == null) return null;
      final handled = await _lastHandledAlarmKey();
      if (handled == alarm.key) return null;
      await _markAlarmHandled(alarm);
      return alarm;
    } catch (e) {
      debugPrint('pendingLaunchAlarm failed: $e');
      return null;
    }
  }

  static Future<String?> _lastHandledAlarmKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyLastHandledAlarm);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _markAlarmHandled(AlarmInfo alarm) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastHandledAlarm, alarm.key);
    } catch (_) {}
  }

  static NotificationDetails _details(AndroidNotificationDetails android) {
    return NotificationDetails(
      android: android,
      iOS: const DarwinNotificationDetails(),
    );
  }

  /// Show an immediate notification using the shared plugin instance.
  static Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();
    await _notifications.show(id, title, body, _details(_androidDetails),
        payload: payload);
  }

  static Future<bool> scheduleTaskReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    if (kIsWeb) {
      return true;
    }
    await ensureInitialized();
    final now = DateTime.now();
    final notificationAllowed = await notificationsAllowed();
    final exactAccess = await AlarmChannel.canScheduleExactAlarms();
    debugPrint(
      'Reminder schedule id=$id due=$scheduledDate now=$now '
      'timezone=${tz.local.name} notificationsAllowed=$notificationAllowed '
      'exactAccess=$exactAccess',
    );
    if (!notificationAllowed) {
      return false;
    }
    if (!scheduledDate.isAfter(now)) {
      debugPrint(
          'Skipping reminder id=$id: $scheduledDate is in the past (now=$now)');
      return false;
    }

    final safeId = id & 0x7FFFFFFF;
    try {
      await _notifications.zonedSchedule(
        safeId,
        title,
        body,
        _toTZDate(scheduledDate),
        _details(_androidDetails),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint(
          'Scheduled reminder id=$id exact=true: "$body" at $scheduledDate');
      return true;
    } catch (error) {
      debugPrint('Exact schedule failed for id=$id ($error); retrying inexact');
      try {
        await _notifications.zonedSchedule(
          safeId,
          title,
          body,
          _toTZDate(scheduledDate),
          _details(_androidDetails),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
        debugPrint(
            'Scheduled reminder id=$id exact=false: "$body" at $scheduledDate');
        return true;
      } catch (fallbackError) {
        debugPrint('Failed to schedule reminder id=$id: $fallbackError');
        return false;
      }
    }
  }

  static Future<int> scheduleTaskReminders({
    required String taskId,
    required String taskTitle,
    required DateTime taskDateTime,
    required List<int> reminderMinutes,
  }) async {
    if (kIsWeb) {
      return 0;
    }

    await ensureInitialized();
    final capped = reminderMinutes.length > maxReminders
        ? reminderMinutes.sublist(0, maxReminders)
        : reminderMinutes;
    final now = DateTime.now();
    var scheduled = 0;
    for (final minutes in capped) {
      if (minutes <= 0 || minutes > 1440) {
        debugPrint(
            'Skipping invalid reminder offset task=$taskId minutes=$minutes');
        continue;
      }
      final scheduledDate = taskDateTime.subtract(Duration(minutes: minutes));
      if (!scheduledDate.isAfter(now)) {
        debugPrint(
          'Skipping past reminder task=$taskId minutes=$minutes '
          'scheduled=$scheduledDate now=$now timezone=${tz.local.name}',
        );
        continue;
      }

      final timeStr =
          '${taskDateTime.hour.toString().padLeft(2, '0')}:${taskDateTime.minute.toString().padLeft(2, '0')}';
      final body = minutes <= 1
          ? '$taskTitle starts at $timeStr'
          : 'In $minutes min: $taskTitle at $timeStr';
      final didSchedule = await scheduleTaskReminder(
        id: NotificationId.taskReminder(taskId, minutes),
        title: 'Task Reminder',
        body: body,
        scheduledDate: scheduledDate,
      );
      if (didSchedule) scheduled += 1;
    }
    debugPrint(
      'Task reminder reconciliation task=$taskId requested=${capped.length} '
      'scheduled=$scheduled timezone=${tz.local.name}',
    );
    return scheduled;
  }

  /// Schedules a REAL task alarm at [alarmTime]. The alarm is armed through
  /// Android's AlarmManager itself (AlarmChannel → AlarmScheduler): it fires
  /// at [alarmTime] and the full-screen AlarmActivity rings natively whether
  /// the app is open, backgrounded, or dead — never gated behind a
  /// notification tap. Sound, vibration and snooze come from the global
  /// Settings at ring time.
  static Future<bool> scheduleTaskAlarm({
    required String taskId,
    required String taskTitle,
    required DateTime alarmTime,
  }) async {
    if (kIsWeb) return true;

    final now = DateTime.now();
    final exactAccess = await AlarmChannel.canScheduleExactAlarms();
    debugPrint(
      'Task alarm schedule task=$taskId alarmTime=$alarmTime now=$now '
      'timezone=${tz.local.name} exactAccess=$exactAccess',
    );
    if (!alarmTime.isAfter(now)) {
      debugPrint('Skipping alarm for task $taskId: $alarmTime is in the past');
      return false;
    }

    final result = await AlarmChannel.schedule(
      requestCode: NotificationId.taskAlarm(taskId),
      alarmTime: alarmTime,
      taskId: taskId,
      taskTitle: taskTitle,
    );
    return result.armed;
  }

  /// Re-alarms the same task [duration] from now. Cancels the original
  /// firing alarm first so the two can never ring together, then re-arms the
  /// same request code natively (a snoozed alarm still rings through the
  /// full-screen AlarmActivity with current global settings).
  static Future<bool> snoozeTaskAlarm({
    required String taskId,
    required String taskTitle,
    required Duration duration,
  }) async {
    if (kIsWeb) return true;
    final result = await AlarmChannel.schedule(
      requestCode: NotificationId.taskAlarm(taskId),
      alarmTime: DateTime.now().add(duration),
      taskId: taskId,
      taskTitle: taskTitle,
    );
    return result.armed;
  }

  /// Plays a short sample of the configured alarm sound without stealing the
  /// screen.  Routes through the same in-app audioplayers engine as a real
  /// alarm so the preview always sounds faithful; auto-stops after 6s.
  static Future<void> previewAlarm(AlarmChannelConfig config) async {
    if (kIsWeb) return;
    await AlarmSoundService.playPreview(
      soundId: config.sound.name,
      customUri:
          config.sound == PyloAlarmSound.custom ? config.customUri : null,
    );
  }

  static Future<void> cancelTaskAlarm(String taskId) async {
    if (kIsWeb) return;
    await AlarmChannel.cancel(requestCode: NotificationId.taskAlarm(taskId));
  }

  static Future<void> cancelAllForTask(String taskId,
      {List<int>? reminderMinutes}) async {
    if (kIsWeb) {
      return;
    }
    await ensureInitialized();
    // Any armed native AlarmManager alarm for this task is withdrawn too, so
    // a deleted/completed/edited task can never ring late via the native path.
    await AlarmChannel.cancel(requestCode: NotificationId.taskAlarm(taskId));
    try {
      final ids = <int>{NotificationId.taskAlarm(taskId)};
      if (reminderMinutes != null && reminderMinutes.isNotEmpty) {
        for (final m in reminderMinutes) {
          ids.add(NotificationId.taskReminder(taskId, m));
        }
      }
      for (final m in knownReminderOffsets) {
        ids.add(NotificationId.taskReminder(taskId, m));
      }
      // Without the exact minute list, sweep the full 0–1440 range so a
      // removed custom offset can never leave an orphaned notification.
      if (reminderMinutes == null) {
        for (final id in NotificationId.allReminderIds(taskId)) {
          ids.add(id);
        }
      }
      // Deliver cancels in small bounded batches: pushing 1441 cancels in a
      // single Future.wait floods the platform channel and can stall the app.
      final ordered = ids.toList();
      const batchSize = 100;
      for (var start = 0; start < ordered.length; start += batchSize) {
        final end = start + batchSize > ordered.length
            ? ordered.length
            : start + batchSize;
        await Future.wait(
            ordered.sublist(start, end).map(_notifications.cancel));
      }
    } catch (e) {
      debugPrint('Failed to cancel notifications for task $taskId: $e');
    }
  }

  static Future<void> scheduleYearlyReminder({
    required String key,
    required String title,
    required String body,
    required DateTime firstOccurrence,
  }) async {
    if (kIsWeb) {
      return;
    }
    // Birthday reminders can fire concurrently with cold-start init; gate on
    // the plugin being ready so a zonedSchedule can never race ahead of
    // initialization and get silently dropped (MissingPluginException).
    await ensureInitialized();
    final now = DateTime.now();
    var scheduled = firstOccurrence;
    if (!scheduled.isAfter(now)) {
      final nextYear = now.year + 1;
      // Clamp to the real last day of the target month/year. DateTime()
      // would otherwise silently roll Feb 29 over to Mar 1, turning a
      // Feb-29 birthday into a never-ending Mar-1 reminder.
      final lastDay = DateTime(nextYear, firstOccurrence.month + 1, 0).day;
      final safeDay = firstOccurrence.day.clamp(1, lastDay);
      scheduled = DateTime(nextYear, firstOccurrence.month, safeDay,
          firstOccurrence.hour, firstOccurrence.minute);
    }

    // Birthday IDs use an offset namespace to prevent collisions with task IDs.
    final notificationId =
        (key.hashCode + NotificationId.birthdayOffset) & 0x7FFFFFFF;

    try {
      await _notifications.zonedSchedule(
        notificationId,
        title,
        body,
        _toTZDate(scheduled),
        _details(_birthdayDetails),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dateAndTime,
      );
      debugPrint('Scheduled yearly reminder "$title" at $scheduled');
    } catch (e) {
      debugPrint(
          'Exact yearly schedule failed for "$title" ($e); retrying inexact');
      try {
        await _notifications.zonedSchedule(
          notificationId,
          title,
          body,
          _toTZDate(scheduled),
          _details(_birthdayDetails),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dateAndTime,
        );
      } catch (e2) {
        debugPrint('Failed to schedule yearly reminder "$title": $e2');
      }
    }
  }

  static Future<void> scheduleBirthdayReminders({
    required String birthdayId,
    required String name,
    required DateTime nextBirthday,
    required List<int> reminderDaysBefore,
    int reminderHour = 9,
    int reminderMinute = 0,
  }) async {
    if (kIsWeb) {
      return;
    }
    final now = DateTime.now();

    await cancelAllForBirthday(birthdayId);

    final dateStr = '${nextBirthday.day}/${nextBirthday.month}';

    for (final days in reminderDaysBefore) {
      // Build the scheduled DateTime with the user's chosen reminder time.
      final reminderDate = DateTime(
        nextBirthday.year,
        nextBirthday.month,
        nextBirthday.day,
        reminderHour,
        reminderMinute,
      ).subtract(Duration(days: days));

      final body = days == 0
          ? "Today is $name's birthday! ($dateStr)"
          : days == 1
              ? "$name's birthday is tomorrow! ($dateStr)"
              : "$name's birthday in $days days ($dateStr)";

      // When the requested lead time has already passed but the birthday
      // itself is still ahead, schedule on the birthday instead of letting
      // scheduleYearlyReminder push the reminder a full year out (which would
      // silently skip this whole cycle).
      var firstOccurrence = reminderDate;
      if (!firstOccurrence.isAfter(now)) {
        firstOccurrence = DateTime(
          nextBirthday.year,
          nextBirthday.month,
          nextBirthday.day,
          reminderHour,
          reminderMinute,
        );
      }

      // Stable id per (birthday, offset): re-scheduling overwrites the
      // previous year's notification instead of stacking a new one each
      // year, and cancelAllForBirthday can always find it.
      await scheduleYearlyReminder(
        key: '$birthdayId-$days',
        // Offset birthday IDs into a separate namespace to avoid collisions
        // with task reminder IDs that use raw hashCode.
        title: days == 0 ? 'Birthday Today' : 'Birthday Reminder',
        body: body,
        firstOccurrence: firstOccurrence,
      );
    }
  }

  static Future<void> cancelAllForBirthday(String birthdayId) async {
    if (kIsWeb) {
      return;
    }
    await ensureInitialized();
    // Batch cancel: cancel current year IDs and legacy year IDs concurrently.
    // Birthday IDs use the offset namespace.
    final cancelFutures = <Future<void>>[];
    for (final days in [0, 1, 3, 7]) {
      final id =
          (('$birthdayId-$days'.hashCode) + NotificationId.birthdayOffset) &
              0x7FFFFFFF;
      cancelFutures.add(_notifications.cancel(id));
      // Legacy ids (older builds) included a birth-year suffix.
      final now = DateTime.now();
      for (var year = now.year - 2; year <= now.year + 2; year++) {
        final legacyId = (('$birthdayId-$days-$year'.hashCode) +
                NotificationId.birthdayOffset) &
            0x7FFFFFFF;
        cancelFutures.add(_notifications.cancel(legacyId));
      }
    }
    await Future.wait(cancelFutures);
  }

  static Future<void> showFocusOngoing({
    required String label,
    required DateTime endTime,
    required bool isStrict,
  }) async {
    if (kIsWeb) return;
    final remaining = endTime.difference(DateTime.now());
    final mins = remaining.inMinutes;
    try {
      await _notifications.show(
        FocusNotificationIds.ongoing,
        isStrict ? 'Strict Focus' : 'Focus Mode',
        mins > 0 ? '$label • $mins min remaining' : '$label • finishing…',
        _details(_focusDetails),
      );
    } catch (e) {
      debugPrint('Focus notification failed: $e');
    }
  }

  static Future<void> scheduleFocusComplete({
    required String label,
    required DateTime endTime,
  }) async {
    if (kIsWeb) return;
    try {
      await _notifications.zonedSchedule(
        FocusNotificationIds.complete,
        'Focus Complete!',
        'Nice work — $label session finished.',
        _toTZDate(endTime),
        _details(_androidDetails),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('Failed to schedule focus completion: $e');
    }
  }

  static Future<void> cancelFocusNotifications() async {
    if (kIsWeb) return;
    await _notifications.cancel(FocusNotificationIds.ongoing);
    await _notifications.cancel(FocusNotificationIds.complete);
  }

  static Future<void> cancel(int id) async {
    if (kIsWeb) {
      return;
    }
    await _notifications.cancel(id);
  }

  static tz.TZDateTime _toTZDate(DateTime date) {
    return tz.TZDateTime.from(date, tz.local);
  }

  /// Shared zonedSchedule for use by NotificationService and other callers.
  static Future<void> zonedSchedule(
    int id,
    String title,
    String body,
    tz.TZDateTime scheduledDate,
    NotificationDetails details, {
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();
    try {
      await _notifications.zonedSchedule(
        id,
        title,
        body,
        scheduledDate,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: matchDateTimeComponents,
      );
    } catch (e) {
      debugPrint('Exact zonedSchedule failed id=$id ($e); retrying inexact');
      try {
        await _notifications.zonedSchedule(
          id,
          title,
          body,
          scheduledDate,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: matchDateTimeComponents,
        );
      } catch (e2) {
        debugPrint('Failed to zonedSchedule id=$id: $e2');
      }
    }
  }

  /// Cancel all notifications across all channels.
  static Future<void> cancelAll() async {
    if (kIsWeb) return;
    await ensureInitialized();
    await _notifications.cancelAll();
  }

  /// Request notification permissions (iOS).
  static Future<bool> requestPermissions() async {
    if (kIsWeb) return true;
    await ensureInitialized();
    final platform = _notifications.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (platform != null) {
      final permissions = await platform.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return permissions != null;
    }
    return true;
  }

  /// Whether Android can arm EXACT alarms (SCHEDULE_EXACT_ALARM special access,
  /// Android 12+; always true on older versions). The native scheduler falls
  /// back to a best-effort inexact alarm when false so rings still happen,
  /// just possibly a little late.
  static Future<bool> canScheduleExactAlarms() async {
    if (kIsWeb) return true;
    return AlarmChannel.canScheduleExactAlarms();
  }

  /// Android 12+: opens the system "Alarms & reminders" screen so the user can
  /// grant exact alarm access. No-op on older versions.
  static Future<void> openExactAlarmSettings() async {
    if (kIsWeb) return;
    await AlarmChannel.openExactAlarmSettings();
  }

  static Future<bool> canUseFullScreenIntent() async {
    if (kIsWeb) return true;
    return AlarmChannel.canUseFullScreenIntent();
  }

  static Future<void> openFullScreenIntentSettings() async {
    if (kIsWeb) return;
    await AlarmChannel.openFullScreenIntentSettings();
  }
}

class FocusNotificationIds {
  static const ongoing = 910001;
  static const complete = 910002;
}
