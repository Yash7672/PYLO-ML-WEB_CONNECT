import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AlarmScheduleResult {
  const AlarmScheduleResult({
    required this.armed,
    required this.exact,
    required this.exactAccess,
    this.error,
  });

  final bool armed;
  final bool exact;
  final bool exactAccess;
  final String? error;

  factory AlarmScheduleResult.fromPlatform(Object? value) {
    if (value is bool) {
      return AlarmScheduleResult(
        armed: value,
        exact: value,
        exactAccess: value,
      );
    }
    if (value is Map) {
      return AlarmScheduleResult(
        armed: value['armed'] == true,
        exact: value['exact'] == true,
        exactAccess: value['exactAccess'] == true,
        error: value['error']?.toString(),
      );
    }
    return const AlarmScheduleResult(
      armed: false,
      exact: false,
      exactAccess: false,
      error: 'Invalid native alarm response',
    );
  }
}

class AlarmChannel {
  AlarmChannel._();

  static const MethodChannel _channel = MethodChannel('pylo/alarm');

  static Future<AlarmScheduleResult> schedule({
    required int requestCode,
    required DateTime alarmTime,
    required String taskId,
    required String taskTitle,
  }) async {
    try {
      final response = await _channel.invokeMethod<Object?>('scheduleAlarm', {
        'requestCode': requestCode,
        'timeMs': alarmTime.millisecondsSinceEpoch,
        'taskId': taskId,
        'title': taskTitle,
      });
      final result = AlarmScheduleResult.fromPlatform(response);
      debugPrint(
        'AlarmChannel.schedule task=$taskId requestCode=$requestCode '
        'armed=${result.armed} exact=${result.exact} '
        'exactAccess=${result.exactAccess} error=${result.error}',
      );
      return result;
    } catch (error) {
      debugPrint('AlarmChannel.schedule failed task=$taskId: $error');
      return AlarmScheduleResult(
        armed: false,
        exact: false,
        exactAccess: false,
        error: error.toString(),
      );
    }
  }

  static Future<void> cancel({required int requestCode}) async {
    try {
      await _channel.invokeMethod('cancelAlarm', {
        'requestCode': requestCode,
      });
      debugPrint('AlarmChannel.cancel requestCode=$requestCode');
    } catch (error) {
      debugPrint('AlarmChannel.cancel failed requestCode=$requestCode: $error');
    }
  }

  static Future<bool> canScheduleExactAlarms() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('canScheduleExactAlarms');
      return result ?? true;
    } catch (error) {
      debugPrint('AlarmChannel.canScheduleExactAlarms failed: $error');
      return true;
    }
  }

  static Future<bool> canUseFullScreenIntent() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('canUseFullScreenIntent');
      return result ?? true;
    } catch (error) {
      debugPrint('AlarmChannel.canUseFullScreenIntent failed: $error');
      return true;
    }
  }

  static Future<void> openExactAlarmSettings() async {
    try {
      await _channel.invokeMethod('openExactAlarmSettings');
    } catch (error) {
      debugPrint('AlarmChannel.openExactAlarmSettings failed: $error');
    }
  }

  static Future<void> openFullScreenIntentSettings() async {
    try {
      await _channel.invokeMethod('openFullScreenIntentSettings');
    } catch (error) {
      debugPrint('AlarmChannel.openFullScreenIntentSettings failed: $error');
    }
  }
}
