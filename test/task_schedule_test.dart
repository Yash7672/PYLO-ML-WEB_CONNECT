import 'package:flutter_test/flutter_test.dart';
import 'package:task_app/core/services/alarm_channel.dart';
import 'package:task_app/core/utils/task_schedule.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  group('TaskScheduleTimes', () {
    test('calculates five and ten minute reminders', () {
      final due = DateTime(2026, 9, 25, 10, 0);
      expect(
        TaskScheduleTimes.reminderTime(taskDateTime: due, minutes: 5),
        DateTime(2026, 9, 25, 9, 55),
      );
      expect(
        TaskScheduleTimes.reminderTime(taskDateTime: due, minutes: 10),
        DateTime(2026, 9, 25, 9, 50),
      );
    });

    test('rejects reminder offsets outside the supported range', () {
      final due = DateTime(2026, 9, 25, 10);
      expect(
        () => TaskScheduleTimes.reminderTime(taskDateTime: due, minutes: 0),
        throwsRangeError,
      );
      expect(
        () => TaskScheduleTimes.reminderTime(taskDateTime: due, minutes: 1441),
        throwsRangeError,
      );
    });

    test('uses an explicit start time before the due date', () {
      final start = DateTime(2026, 9, 25, 14, 30);
      expect(
        TaskScheduleTimes.eventTime(
          dueDate: DateTime(2026, 9, 30),
          startTime: start,
          now: DateTime(2026, 9, 25),
        ),
        start,
      );
    });

    test('uses a future nine oclock time for date-only due dates', () {
      expect(
        TaskScheduleTimes.eventTime(
          dueDate: DateTime(2026, 9, 25),
          now: DateTime(2026, 9, 25, 7),
        ),
        DateTime(2026, 9, 25, 9),
      );
    });

    test('preserves the instant when the event is in a named timezone', () {
      final due = tz.TZDateTime.from(
        DateTime.utc(2026, 9, 25, 10),
        tz.UTC,
      );
      final reminder = TaskScheduleTimes.reminderTime(
        taskDateTime: due,
        minutes: 5,
      );
      expect(
          reminder.millisecondsSinceEpoch, due.millisecondsSinceEpoch - 300000);
      expect(reminder.isUtc, isTrue);
    });

    test('new task due date leaves room for a ten minute reminder', () {
      final now = DateTime(2026, 9, 25, 10);
      expect(
        TaskScheduleTimes.newTaskDueDate(now: now),
        DateTime(2026, 9, 25, 10, 10),
      );
    });
  });

  group('AlarmScheduleResult', () {
    test('parses the native structured result', () {
      final result = AlarmScheduleResult.fromPlatform({
        'armed': true,
        'exact': false,
        'exactAccess': false,
        'error': 'inexact',
      });
      expect(result.armed, isTrue);
      expect(result.exact, isFalse);
      expect(result.exactAccess, isFalse);
      expect(result.error, 'inexact');
    });

    test('rejects a malformed native result', () {
      final result = AlarmScheduleResult.fromPlatform('invalid');
      expect(result.armed, isFalse);
      expect(result.error, isNotNull);
    });
  });
}
