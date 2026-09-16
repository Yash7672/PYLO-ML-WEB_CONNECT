import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../models/birthday_model.dart';
import '../models/checklist_model.dart';
import '../models/habit_model.dart';
import '../models/task_model.dart';

class _ChecklistRow {
  final String text;
  final bool isGroup;
  const _ChecklistRow({required this.text, required this.isGroup});
}

class HomeWidgetService {
  static const _androidProviderName =
      'com.example.task_app.PyloHomeWidgetProvider';
  static const _habitsProviderName =
      'com.example.task_app.PyloHabitsWidgetProvider';
  static const _progressProviderName =
      'com.example.task_app.PyloProgressWidgetProvider';
  static const _quickAddProviderName =
      'com.example.task_app.PyloQuickAddWidgetProvider';
  static const _focusProviderName =
      'com.example.task_app.PyloFocusWidgetProvider';
  static const _checklistProviderName =
      'com.example.task_app.PyloChecklistWidgetProvider';
  static const _birthdaysProviderName =
      'com.example.task_app.PyloBirthdaysWidgetProvider';
  static const _appGroupId = 'pylo.home_widget';

  static bool _initialized = false;
  static Timer? _debounce;

  /// Widget providers whose backing data changed since the last flush. The
  /// debounced [_flush] updates ONLY these so a task mutation never re-renders
  /// unrelated checklist/birthday/focus widgets and vice-versa.
  static final Set<String> _dirtyProviders = {};

  static List<Task> _todayTasks = const [];
  static List<Habit> _habits = const [];
  static int _bestStreak = 0;

  static Future<void> init() async {
    if (_initialized) return;
    try {
      await HomeWidget.setAppGroupId(_appGroupId);
      _initialized = true;
    } catch (e) {
      debugPrint('HomeWidget init failed: $e');
    }
  }

  // ── Task data ──────────────────────────────────────────────────────

  /// True when [task] is due on the same local calendar date as [date].
  /// The time-of-day component is deliberately ignored.
  static bool isDueOn(Task task, DateTime date) {
    if (task.isDeleted || task.isArchived) return false;
    return task.dueDate.year == date.year &&
        task.dueDate.month == date.month &&
        task.dueDate.day == date.day;
  }

  /// Keeps only tasks whose due date is exactly the device's current local
  /// calendar date. Future and past-day tasks are never shown.
  static void refreshTasks(List<Task> allTasks) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _todayTasks =
        allTasks.where((task) => isDueOn(task, today)).toList();
    // Today Tasks, Progress and Quick-Add all read task data — update only
    // those, not every widget on the home screen.
    _markDirty({
      _androidProviderName,
      _progressProviderName,
      _quickAddProviderName,
    });
    _scheduleFlush();
  }

  // ── Habit data ─────────────────────────────────────────────────────

  static void refreshHabits(int bestStreak, {List<Habit>? habits}) {
    _bestStreak = bestStreak;
    if (habits != null) _habits = habits;
    // A habit change only affects the dedicated Habits widget — the Today's
    // Tasks widget no longer renders any streak, so leave it untouched.
    _markDirty({_habitsProviderName});
    _scheduleFlush();
  }

  static void _markDirty(Set<String> providers) {
    if (kIsWeb) return;
    _dirtyProviders.addAll(providers);
  }

  // ── Immediate push ─────────────────────────────────────────────────

  static Future<void> pushNow() async {
    if (kIsWeb) return;
    await init();
    await _flush();
  }

  // ── Widget pinning ─────────────────────────────────────────────────

  static Future<void> requestPinWidget() async {
    if (kIsWeb) return;
    try {
      await init();
      await HomeWidget.requestPinWidget(
        androidName: 'PyloHomeWidgetProvider',
        qualifiedAndroidName: _androidProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget pin request failed: $e');
    }
  }

  static Future<void> requestPinHabitsWidget() async {
    if (kIsWeb) return;
    try {
      await init();
      await HomeWidget.requestPinWidget(
        androidName: 'PyloHabitsWidgetProvider',
        qualifiedAndroidName: _habitsProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget pin habits failed: $e');
    }
  }

  static Future<void> requestPinProgressWidget() async {
    if (kIsWeb) return;
    try {
      await init();
      await HomeWidget.requestPinWidget(
        androidName: 'PyloProgressWidgetProvider',
        qualifiedAndroidName: _progressProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget pin progress failed: $e');
    }
  }

  static Future<void> requestPinQuickAddWidget() async {
    if (kIsWeb) return;
    try {
      await init();
      await HomeWidget.requestPinWidget(
        androidName: 'PyloQuickAddWidgetProvider',
        qualifiedAndroidName: _quickAddProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget pin quick add failed: $e');
    }
  }

  static Future<void> requestPinFocusWidget() async {
    if (kIsWeb) return;
    try {
      await init();
      await HomeWidget.requestPinWidget(
        androidName: 'PyloFocusWidgetProvider',
        qualifiedAndroidName: _focusProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget pin focus failed: $e');
    }
  }

  static Future<void> requestPinChecklistWidget() async {
    if (kIsWeb) return;
    try {
      await init();
      await HomeWidget.requestPinWidget(
        androidName: 'PyloChecklistWidgetProvider',
        qualifiedAndroidName: _checklistProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget pin checklist failed: $e');
    }
  }

  static Future<void> requestPinBirthdaysWidget() async {
    if (kIsWeb) return;
    try {
      await init();
      await HomeWidget.requestPinWidget(
        androidName: 'PyloBirthdaysWidgetProvider',
        qualifiedAndroidName: _birthdaysProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget pin birthdays failed: $e');
    }
  }

  // ── Debounced flush ────────────────────────────────────────────────

  static void _scheduleFlush() {
    if (kIsWeb) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      unawaited(_flush());
    });
  }

  // ── Core data push to SharedPreferences ────────────────────────────

  static bool _focusDefaultsSet = false;

  static Future<void> _flush() async {
    try {
      await init();

      // ── Today Tasks widget data ──
      final pendingTasks = _todayTasks.where((t) => !t.isCompleted).toList();
      final completedTasks = _todayTasks.where((t) => t.isCompleted).toList();
      final allDisplayTasks = [...pendingTasks, ...completedTasks];
      final totalToday = _todayTasks.length;
      final doneCount = completedTasks.length;
      final pendingCount = pendingTasks.length;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Batch task writes concurrently
      final taskFutures = <Future<void>>[
        HomeWidget.saveWidgetData<int>('tasks_total', totalToday),
        HomeWidget.saveWidgetData<int>('tasks_done', doneCount),
        HomeWidget.saveWidgetData<int>('tasks_pending', pendingCount),
        HomeWidget.saveWidgetData<int>(
            'tasks_more', allDisplayTasks.length > 5 ? allDisplayTasks.length - 5 : 0),
        HomeWidget.saveWidgetData<String>('tasks_last_updated', now.toString()),
      ];

      for (var i = 0; i < 5; i++) {
        if (i < allDisplayTasks.length) {
          final t = allDisplayTasks[i];
          taskFutures.add(HomeWidget.saveWidgetData<String>('tasks_title_$i', t.title));
          taskFutures.add(HomeWidget.saveWidgetData<String>('tasks_id_$i', t.id));
          taskFutures.add(HomeWidget.saveWidgetData<bool>('tasks_done_$i', t.isCompleted));
        } else {
          taskFutures.add(HomeWidget.saveWidgetData<String>('tasks_title_$i', ''));
          taskFutures.add(HomeWidget.saveWidgetData<String>('tasks_id_$i', ''));
          taskFutures.add(HomeWidget.saveWidgetData<bool>('tasks_done_$i', false));
        }
      }

      // ── Habits widget data ──
      final habitsCompletedToday = _habits.where((h) => h.isCompletedToday).length;
      taskFutures.addAll([
        HomeWidget.saveWidgetData<int>('habits_best_streak', _bestStreak),
        HomeWidget.saveWidgetData<int>('habits_count', _habits.length),
        HomeWidget.saveWidgetData<int>('habits_completed_today', habitsCompletedToday),
        HomeWidget.saveWidgetData<String>('habits_last_updated', now.toString()),
      ]);

      for (var i = 0; i < 5; i++) {
        if (i < _habits.length) {
          final h = _habits[i];
          taskFutures.add(HomeWidget.saveWidgetData<String>('habits_name_$i', h.name));
          taskFutures.add(HomeWidget.saveWidgetData<String>('habits_id_$i', h.id));
          taskFutures.add(HomeWidget.saveWidgetData<int>(
              'habits_streak_$i', h.effectiveCurrentStreak()));
        } else {
          taskFutures.add(HomeWidget.saveWidgetData<String>('habits_name_$i', ''));
          taskFutures.add(HomeWidget.saveWidgetData<String>('habits_id_$i', ''));
        }
      }

      // ── Progress widget data ──
      final percent = totalToday > 0 ? ((doneCount / totalToday) * 100).round() : 0;
      taskFutures.addAll([
        HomeWidget.saveWidgetData<int>('progress_total', totalToday),
        HomeWidget.saveWidgetData<int>('progress_done', doneCount),
        HomeWidget.saveWidgetData<int>('progress_percent', percent),
        HomeWidget.saveWidgetData<int>('progress_remaining', pendingCount),
        HomeWidget.saveWidgetData<String>('progress_last_updated', now.toString()),
      ]);

      await Future.wait(taskFutures);

      // ── Default data for focus widget (once only) ──
      if (!_focusDefaultsSet) {
        final existingFocusActive = await HomeWidget.getWidgetData<bool>('focus_active');
        if (existingFocusActive == null) {
          await Future.wait([
            HomeWidget.saveWidgetData<bool>('focus_active', false),
            HomeWidget.saveWidgetData<String>('focus_label', ''),
            HomeWidget.saveWidgetData<int>('focus_remaining_minutes', 0),
            HomeWidget.saveWidgetData<int>('focus_remaining_seconds', 0),
            HomeWidget.saveWidgetData<bool>('focus_strict', false),
          ]);
        }
        _focusDefaultsSet = true;
      }

      await _updatePendingWidgets();
    } catch (e) {
      debugPrint('HomeWidget flush failed: $e');
    }
  }

  // ── Focus widget data ─────────────────────────────────────────────

  static Future<void> refreshFocus({
    required bool isActive,
    required String label,
    required int remainingMinutes,
    required int remainingSeconds,
    required bool isStrict,
  }) async {
    if (kIsWeb) return;
    try {
      await init();
      await Future.wait([
        HomeWidget.saveWidgetData<bool>('focus_active', isActive),
        HomeWidget.saveWidgetData<String>('focus_label', label),
        HomeWidget.saveWidgetData<int>('focus_remaining_minutes', remainingMinutes),
        HomeWidget.saveWidgetData<int>('focus_remaining_seconds', remainingSeconds),
        HomeWidget.saveWidgetData<bool>('focus_strict', isStrict),
        HomeWidget.saveWidgetData<String>(
            'focus_last_updated', DateTime.now().millisecondsSinceEpoch.toString()),
      ]);
      await HomeWidget.updateWidget(
        androidName: 'PyloFocusWidgetProvider',
        qualifiedAndroidName: _focusProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget refreshFocus failed: $e');
    }
  }

  // ── Checklist widget data (hierarchical) ──────────────────────────

  static Future<void> refreshChecklist({
    required List<Checklist> checklists,
    required Map<String, List<ChecklistItem>> items,
  }) async {
    if (kIsWeb) return;
    try {
      await init();

      // Flatten into rows: group headers + their items
      final rows = <_ChecklistRow>[];
      for (final checklist in checklists) {
        final checklistItems = items[checklist.id] ?? const [];
        rows.add(_ChecklistRow(text: checklist.title, isGroup: true));
        for (final item in checklistItems) {
          rows.add(_ChecklistRow(text: item.text, isGroup: false));
        }
      }

      final futures = <Future<void>>[
        HomeWidget.saveWidgetData<int>('checklist_count', rows.length),
      ];

      for (var i = 0; i < 8; i++) {
        if (i < rows.length) {
          futures.add(HomeWidget.saveWidgetData<String>('checklist_text_$i', rows[i].text));
          futures.add(HomeWidget.saveWidgetData<bool>('checklist_is_group_$i', rows[i].isGroup));
        } else {
          futures.add(HomeWidget.saveWidgetData<String>('checklist_text_$i', ''));
        }
      }

      futures.add(HomeWidget.saveWidgetData<String>(
          'checklist_last_updated', DateTime.now().millisecondsSinceEpoch.toString()));
      await Future.wait(futures);
      await HomeWidget.updateWidget(
        androidName: 'PyloChecklistWidgetProvider',
        qualifiedAndroidName: _checklistProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget refreshChecklist failed: $e');
    }
  }

  // ── Birthdays widget data ─────────────────────────────────────────

  /// Month/day markers for EVERY saved birthday, independent of the current
  /// date, so the native calendar can show 🎂 on the matching days of any
  /// navigated month. Format: "MM-DD,MM-DD" with zero-padded values.
  static String _birthdayMarkerOf(Birthday b) {
    final m = b.birthDate.month.toString().padLeft(2, '0');
    final d = b.birthDate.day.toString().padLeft(2, '0');
    return '$m-$d';
  }

  static Future<void> refreshBirthdays(List<Birthday> birthdays) async {
    if (kIsWeb) return;
    try {
      await init();
      final markers =
          birthdays.map(_birthdayMarkerOf).where((m) => m.isNotEmpty).join(',');

      final futures = <Future<void>>[
        HomeWidget.saveWidgetData<int>('birthdays_count', birthdays.length),
        HomeWidget.saveWidgetData<String>('birthday_markers', markers),
      ];

      // Keep the viewed month sensible: reset only when it is missing or now
      // in the past (the device date moved past it). Deliberate navigation to
      // future months survives app restarts and unrelated widget pushes.
      final now = DateTime.now();
      final currentYyyymm = now.year * 100 + now.month;
      final storedViewMonth =
          await HomeWidget.getWidgetData<int>('birthday_view_month');
      final viewMonth = (storedViewMonth ?? 0) < currentYyyymm
          ? currentYyyymm
          : (storedViewMonth ?? currentYyyymm);
      if (viewMonth != storedViewMonth) {
        futures.add(HomeWidget.saveWidgetData<int>('birthday_view_month', viewMonth));
      }

      futures.add(HomeWidget.saveWidgetData<String>(
          'birthdays_last_updated', DateTime.now().millisecondsSinceEpoch.toString()));
      await Future.wait(futures);
      await HomeWidget.updateWidget(
        androidName: 'PyloBirthdaysWidgetProvider',
        qualifiedAndroidName: _birthdaysProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget refreshBirthdays failed: $e');
    }
  }

  // ── Update all widgets ────────────────────────────────────────────

  /// Pushes today's tasks to the widget store and refreshes ONLY the Today
  /// Tasks widget. Used by the background callback (widget checkbox taps)
  /// where updating every widget would be wasteful.
  static Future<void> refreshTodayTasksWidget(List<Task> allTasks) async {
    if (kIsWeb) return;
    try {
      await init();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final todayTasks = allTasks.where((t) => isDueOn(t, today)).toList();

      final pendingTasks =
          todayTasks.where((t) => !t.isCompleted).toList();
      final completedTasks = todayTasks.where((t) => t.isCompleted).toList();
      final allDisplayTasks = [...pendingTasks, ...completedTasks];
      final doneCount = completedTasks.length;

      final futures = <Future<void>>[
        HomeWidget.saveWidgetData<int>('tasks_total', todayTasks.length),
        HomeWidget.saveWidgetData<int>('tasks_done', doneCount),
        HomeWidget.saveWidgetData<int>('tasks_pending', pendingTasks.length),
        HomeWidget.saveWidgetData<int>('tasks_more',
            allDisplayTasks.length > 5 ? allDisplayTasks.length - 5 : 0),
        HomeWidget.saveWidgetData<String>('tasks_last_updated',
            DateTime.now().millisecondsSinceEpoch.toString()),
      ];

      for (var i = 0; i < 5; i++) {
        if (i < allDisplayTasks.length) {
          final t = allDisplayTasks[i];
          futures.add(HomeWidget.saveWidgetData<String>('tasks_title_$i', t.title));
          futures.add(HomeWidget.saveWidgetData<String>('tasks_id_$i', t.id));
          futures.add(HomeWidget.saveWidgetData<bool>('tasks_done_$i', t.isCompleted));
        } else {
          futures.add(HomeWidget.saveWidgetData<String>('tasks_title_$i', ''));
          futures.add(HomeWidget.saveWidgetData<String>('tasks_id_$i', ''));
          futures.add(HomeWidget.saveWidgetData<bool>('tasks_done_$i', false));
        }
      }

      await Future.wait(futures);
      await HomeWidget.updateWidget(
        androidName: 'PyloHomeWidgetProvider',
        qualifiedAndroidName: _androidProviderName,
      );
    } catch (e) {
      debugPrint('HomeWidget refreshTodayTasksWidget failed: $e');
    }
  }

  static Future<void> _updatePendingWidgets() async {
    // When nothing is marked dirty (e.g. an explicit pushNow), fall back to a
    // full refresh so direct callers always get the complete update.
    var providers = _dirtyProviders.toList();
    _dirtyProviders.clear();
    if (providers.isEmpty) {
      providers = const [
        _androidProviderName,
        _habitsProviderName,
        _progressProviderName,
        _quickAddProviderName,
      ];
    }
    // Update all dirty widgets concurrently instead of sequentially.
    await Future.wait(
      providers.map((name) async {
        try {
          await HomeWidget.updateWidget(
            androidName: name.split('.').last,
            qualifiedAndroidName: name,
          );
        } catch (e) {
          debugPrint('HomeWidget update $name failed: $e');
        }
      }),
    );
  }

  // ── Deferred alarm cancels (widget checkbox taps) ──────────────────

  /// Mailbox key for task ids whose alarm/reminders must be withdrawn once
  /// the MAIN isolate is running.
  static const String _pendingAlarmCancelKey = 'pylo_pending_alarm_cancels';

  /// Upper bound on the mailbox so a pathological burst of widget taps can
  /// never grow it without limit.
  static const int _maxPendingAlarmCancels = 50;

  /// Queues [taskId] so the main isolate withdraws its pending alarm and
  /// reminders.
  ///
  /// Called from the widget background isolate, where the notification and
  /// AlarmManager plugins are NOT registered — a direct cancel there would
  /// throw MissingPluginException. HomeWidget's own data store IS available in
  /// that isolate, so it is used as the transport.
  static Future<void> queueAlarmCancel(String taskId) async {
    if (kIsWeb || taskId.isEmpty) return;
    try {
      await init();
      final existing =
          await HomeWidget.getWidgetData<String>(_pendingAlarmCancelKey) ?? '';
      final ids = existing.isEmpty ? <String>[] : existing.split(',');
      if (ids.contains(taskId)) return;
      ids.add(taskId);
      final capped = ids.length > _maxPendingAlarmCancels
          ? ids.sublist(ids.length - _maxPendingAlarmCancels)
          : ids;
      await HomeWidget.saveWidgetData<String>(
          _pendingAlarmCancelKey, capped.join(','));
    } catch (e) {
      debugPrint('HomeWidget queueAlarmCancel failed: $e');
    }
  }

  /// Reads AND clears the queued task ids. Main isolate only.
  static Future<List<String>> takePendingAlarmCancels() async {
    if (kIsWeb) return const [];
    try {
      await init();
      final raw = await HomeWidget.getWidgetData<String>(_pendingAlarmCancelKey);
      if (raw == null || raw.isEmpty) return const [];
      await HomeWidget.saveWidgetData<String>(_pendingAlarmCancelKey, '');
      return raw.split(',').where((id) => id.isNotEmpty).toList();
    } catch (e) {
      debugPrint('HomeWidget takePendingAlarmCancels failed: $e');
      return const [];
    }
  }

  // ── Task completion from widget ────────────────────────────────────

  static Future<String?> getWidgetAction() async {
    if (kIsWeb) return null;
    try {
      await init();
      return await HomeWidget.getWidgetData<String>('widget_action');
    } catch (e) {
      debugPrint('HomeWidget getWidgetAction failed: $e');
      return null;
    }
  }

  static Future<String?> getWidgetTaskId() async {
    if (kIsWeb) return null;
    try {
      await init();
      return await HomeWidget.getWidgetData<String>('widget_task_id');
    } catch (e) {
      debugPrint('HomeWidget getWidgetTaskId failed: $e');
      return null;
    }
  }

  static Future<void> clearWidgetAction() async {
    if (kIsWeb) return;
    try {
      await init();
      await Future.wait([
        HomeWidget.saveWidgetData<String>('widget_action', ''),
        HomeWidget.saveWidgetData<String>('widget_task_id', ''),
      ]);
    } catch (e) {
      debugPrint('HomeWidget clearWidgetAction failed: $e');
    }
  }

  // ── Convenience: refresh everything ────────────────────────────────

  static Future<void> refreshAll({
    required List<Task> tasks,
    required List<Habit> habits,
    required int bestStreak,
  }) async {
    refreshTasks(tasks);
    refreshHabits(bestStreak, habits: habits);
  }
}
