import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/notification_helper.dart';
import '../database/database_helper.dart';
import '../models/birthday_model.dart';
import '../services/home_widget_service.dart';
import 'database_provider.dart';

final birthdayProvider =
    StateNotifierProvider<BirthdayNotifier, AsyncValue<List<Birthday>>>((ref) {
  final dbHelper = ref.watch(databaseProvider);
  return BirthdayNotifier(dbHelper);
});

class BirthdayNotifier extends StateNotifier<AsyncValue<List<Birthday>>> {
  final DatabaseHelper dbHelper;
  Timer? _midnightTimer;
  Future<void>? _appendQueue;

  BirthdayNotifier(this.dbHelper) : super(const AsyncValue.loading()) {
    loadBirthdays();
    _armMidnightResort();
  }

  /// Countdowns are relative to "today"; re-sort when the day flips so the
  /// app never shows yesterday's ordering while left open overnight.
  void _armMidnightResort() {
    _midnightTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer = Timer(nextMidnight.difference(now), () {
      if (!mounted) return;
      _resort();
      _armMidnightResort();
    });
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  Future<void>? _loadInFlight;

  /// Loads all birthdays, deduplicating concurrent calls (the constructor
  /// auto-load and [rescheduleAllReminders] from startup share one query).
  Future<void> loadBirthdays() {
    final inFlight = _loadInFlight;
    if (inFlight != null) return inFlight;
    final run = _load();

    _loadInFlight = run.whenComplete(() => _loadInFlight = null);
    return _loadInFlight!;
  }

  Future<void> _load() async {
    try {
      final birthdays = await dbHelper.getAllBirthdays();
      final sorted = [...birthdays]..sort((a, b) =>
          a.daysUntilNext().compareTo(b.daysUntilNext()));
      state = AsyncValue.data(sorted);
      HomeWidgetService.refreshBirthdays(sorted);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  List<Birthday> get _current =>
      state.maybeWhen(data: (b) => b, orElse: () => []);

  void _resort() {
    final sorted = [..._current]..sort((a, b) =>
        a.daysUntilNext().compareTo(b.daysUntilNext()));
    state = AsyncValue.data(sorted);
    HomeWidgetService.refreshBirthdays(sorted);
  }

  Future<void> addBirthday(Birthday birthday,
      {bool notificationsEnabled = true}) async {
    final run = (_appendQueue ?? Future.value()).then((_) async {
      try {
        await dbHelper.createBirthday(birthday);
        state = AsyncValue.data([..._current, birthday]);
        _resort();
        if (notificationsEnabled) {
          await NotificationHelper.scheduleBirthdayReminders(
            birthdayId: birthday.id,
            name: birthday.name,
            nextBirthday: birthday.nextOccurrence(),
            reminderDaysBefore: birthday.reminderDaysBefore,
            reminderHour: birthday.reminderHour,
            reminderMinute: birthday.reminderMinute,
          );
        }
      } catch (e) {
        debugPrint('Error adding birthday: $e');
      }
    });
    _appendQueue = run.catchError((Object _) {});
    await run;
  }

  Future<void> updateBirthday(Birthday birthday,
      {bool notificationsEnabled = true}) async {
    try {
      await dbHelper.updateBirthday(birthday);
      final list = _current;
      final index = list.indexWhere((b) => b.id == birthday.id);
      if (index != -1) {
        final updated = List<Birthday>.from(list);
        updated[index] = birthday;
        state = AsyncValue.data(updated);
        _resort();
      }
      await NotificationHelper.cancelAllForBirthday(birthday.id);
      if (notificationsEnabled) {
        await NotificationHelper.scheduleBirthdayReminders(
          birthdayId: birthday.id,
          name: birthday.name,
          nextBirthday: birthday.nextOccurrence(),
          reminderDaysBefore: birthday.reminderDaysBefore,
          reminderHour: birthday.reminderHour,
          reminderMinute: birthday.reminderMinute,
        );
      }
    } catch (e) {
      debugPrint('Error updating birthday: $e');
    }
  }

  Future<void> deleteBirthday(String id) async {
    try {
      await NotificationHelper.cancelAllForBirthday(id);
      await dbHelper.deleteBirthday(id);
      state = AsyncValue.data(_current.where((b) => b.id != id).toList());
      // Keep the native birthdays widget's calendar in sync after a delete.
      _resort();
    } catch (e) {
      debugPrint('Error deleting birthday: $e');
    }
  }

  /// (Re)schedules reminders for every existing birthday. Called when the
  /// user turns Birthday reminders ON in Settings — without this, birthdays
  /// added while notifications were off would never fire.
  Future<void> rescheduleAllReminders() async {
    // Wait for the (possibly in-flight) initial load so that on a cold start
    // the list is populated before scheduling — otherwise reboot-time reminder
    // rescheduling would silently skip every birthday.
    await loadBirthdays();
    // Each birthday schedule cancels 24 notification ids before re-scheduling;
    // run the per-birthday work concurrently so startup isn't a serial chain
    // of platform-channel round-trips.
    await Future.wait(_current.map((birthday) async {
      try {
        await NotificationHelper.scheduleBirthdayReminders(
          birthdayId: birthday.id,
          name: birthday.name,
          nextBirthday: birthday.nextOccurrence(),
          reminderDaysBefore: birthday.reminderDaysBefore,
          reminderHour: birthday.reminderHour,
          reminderMinute: birthday.reminderMinute,
        );
      } catch (e) {
        debugPrint('Failed to reschedule birthday ${birthday.id}: $e');
      }
    }));
  }
}
