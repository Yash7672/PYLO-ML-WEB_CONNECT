import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database_helper.dart';
import '../models/category_model.dart';
import '../models/habit_completion_item.dart';
import '../models/habit_log_item.dart';
import '../models/habit_model.dart';
import '../models/task_model.dart';
import '../services/home_widget_service.dart';
import '../core/utils/notification_helper.dart';
import 'database_provider.dart';

final taskProvider =
    StateNotifierProvider<TaskNotifier, AsyncValue<List<Task>>>((ref) {
  final dbHelper = ref.watch(databaseProvider);
  return TaskNotifier(dbHelper);
});

class TaskNotifier extends StateNotifier<AsyncValue<List<Task>>> {
  final DatabaseHelper dbHelper;
  Timer? _midnightTimer;

  /// Deduplicates concurrent [loadTasks] calls: the notifier auto-loads at
  /// construction while startup also asks for a reload/reschedule — both share
  /// one DB query instead of running the full-table scan twice back-to-back.
  Future<void>? _loadInFlight;

  /// Serializes ALL task mutations (add/update/delete/restore/archive/…) so
  /// overlapping calls — e.g. swipe-delete followed by an immediate Undo —
  /// run one after the other in deterministic FIFO order. Without this,
  /// a delete and its undo could interleave their DB writes and their state
  /// refreshes, and a restore could be lost (task never comes back).
  Future<void>? _mutationQueue;

  /// Bumped by every mutation that changes task rows. Concurrent reloads
  /// compare against it so a stale snapshot read during a write can never
  /// resurrect rows the user just deleted or restore a task that no longer
  /// exists.
  int _dataRevision = 0;

  /// Enqueues [action] behind any in-flight mutation. Returns the action's
  /// result, so callers can await the true completion of their operation.
  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final result = (_mutationQueue ?? Future.value()).then((_) => action());
    _mutationQueue = result.then<void>((_) {}, onError: (Object e, StackTrace st) {});
    return result;
  }

  TaskNotifier(this.dbHelper) : super(const AsyncValue.loading()) {
    loadTasks();
    _armMidnightReload();
  }

  /// "Today"/"Overdue" lists are computed from DateTime.now(); without this
  /// they go stale when the app stays open across midnight.
  void _armMidnightReload() {
    _midnightTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer = Timer(nextMidnight.difference(now), () async {
      if (!mounted) return;
      await loadTasks();
      _armMidnightReload();
    });
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  Future<void> loadTasks() {
    final inFlight = _loadInFlight;
    if (inFlight != null) return inFlight;
    final run = _doLoadTasks();
    _loadInFlight = run.whenComplete(() => _loadInFlight = null);
    return _loadInFlight!;
  }

  Future<void> _doLoadTasks() async {
    final rev = _dataRevision;
    try {
      // Only flash the loading state when nothing is on screen yet.
      final hasData = state.maybeWhen(data: (_) => true, orElse: () => false);
      if (!hasData) state = const AsyncValue.loading();
      final tasks = await dbHelper.getAllTasks();
      // A mutation landed while we were reading; it already owns state.
      if (rev != _dataRevision) return;
      _updateState(tasks);
    } catch (e, st) {
      if (rev == _dataRevision) state = AsyncValue.error(e, st);
    }
  }

  List<Task> _sortTasks(List<Task> tasks) {
    tasks.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      if (a.isCompleted != b.isCompleted) return a.isCompleted ? 1 : -1;
      return a.dueDate.compareTo(b.dueDate);
    });
    return tasks;
  }

  List<Task> get _currentTasks => state.maybeWhen(
        data: (tasks) => tasks,
        orElse: () => [],
      );

  void _updateState(List<Task> tasks) {
    state = AsyncValue.data(_sortTasks(tasks));
    HomeWidgetService.refreshTasks(tasks);
  }

  Future<void> addTask(Task task) async {
    await _runExclusive(() async {
      try {
        _dataRevision++;
        await dbHelper.createTask(task);
        _updateState([..._currentTasks, task]);
      } catch (e) {
        debugPrint('Error adding task: $e');
        rethrow;
      }
    });
  }

  /// Returns true when the task was persisted AND reflected in state.
  Future<bool> updateTask(Task task) async {
    return _runExclusive(() async {
      try {
        _dataRevision++;
        await dbHelper.updateTask(task);
        final tasks = _currentTasks;
        final index = tasks.indexWhere((t) => t.id == task.id);
        if (index != -1) {
          final updated = List<Task>.from(tasks);
          updated[index] = task;
          _updateState(updated);
        }
        return true;
      } catch (e) {
        debugPrint('Error updating task: $e');
        return false;
      }
    });
  }

  Future<void> archiveTask(String id) async {
    await _runExclusive(() async {
      final tasks = _currentTasks;
      final index = tasks.indexWhere((t) => t.id == id);
      Task? removed;
      if (index != -1) {
        removed = tasks[index];
        final updated = List<Task>.from(tasks);
        updated.removeAt(index);
        _updateState(updated);
      }
      _dataRevision++;
      try {
        await dbHelper.archiveTask(id);
        await NotificationHelper.cancelAllForTask(
          id,
          reminderMinutes: removed?.reminderMinutes,
        );
      } catch (e) {
        debugPrint('Error archiving task: $e');
        await loadTasks();
      }
    });
  }

  /// Restores the exact soft-deleted task row (same id, all original fields)
  /// and reloads state. Returns the restored Task, or null when it could not
  /// be restored, so callers can reschedule reminders only on real success.
  Future<Task?> restoreTask(String id) async {
    Task? restored;
    await _runExclusive(() async {
      try {
        _dataRevision++;
        await dbHelper.restoreTask(id);
        restored = await dbHelper.getTask(id);
        await loadTasks();
      } catch (e) {
        debugPrint('Error restoring task: $e');
      }
    });
    return restored;
  }

  Future<void> restoreTaskFromModel(Task task) async {
    await updateTask(task.restore());
  }

  Future<void> deleteTask(String id) async {
    // Optimistic synchronous removal so the swiped-away Dismissible leaves
    // the tree immediately (a Dismissible must be gone on the next frame).
    final tasks = _currentTasks;
    final index = tasks.indexWhere((t) => t.id == id);
    final removed = index != -1 ? tasks[index] : null;
    if (index != -1) {
      _updateState(List<Task>.from(tasks)..removeAt(index));
    }
    _dataRevision++;
    await _runExclusive(() async {
      try {
        await dbHelper.deleteTask(id);
        await NotificationHelper.cancelAllForTask(
          id,
          reminderMinutes: removed?.reminderMinutes,
        );
      } catch (e) {
        debugPrint('Error deleting task: $e');
      } finally {
        // Re-sync state with the DB so an interleaved reload (e.g. midnight
        // refresh) can never resurrect the row that was just deleted.
        await loadTasks();
      }
    });
  }

  Future<void> deleteTaskPermanently(String id) async {
    await _runExclusive(() async {
      try {
        final tasks = _currentTasks;
        final index = tasks.indexWhere((t) => t.id == id);
        final removed = index != -1 ? tasks[index] : null;
        _dataRevision++;
        await dbHelper.deleteTaskPermanently(id);
        await NotificationHelper.cancelAllForTask(
          id,
          reminderMinutes: removed?.reminderMinutes,
        );
        _updateState(_currentTasks.where((t) => t.id != id).toList());
      } catch (e) {
        debugPrint('Error permanently deleting task: $e');
      }
    });
  }

  Future<void> toggleTaskCompletion(Task task,
      {bool notificationsEnabled = true}) async {
    final nowCompleted = !task.isCompleted;
    final updatedTask = task.copyWith(
      isCompleted: nowCompleted,
      completedAt: nowCompleted ? DateTime.now() : null,
    );
    final persisted = await updateTask(updatedTask);

    // A completed task must not keep firing its pending reminders.
    await NotificationHelper.cancelAllForTask(task.id,
        reminderMinutes: task.reminderMinutes);

    if (!nowCompleted) {
      // Un-completing: put this instance's reminders and alarm back if enabled.
      if (notificationsEnabled) {
        final taskDateTime = updatedTask.startTime ??
            DateTime(updatedTask.dueDate.year, updatedTask.dueDate.month,
                updatedTask.dueDate.day, 9, 0);
        if (updatedTask.reminderMinutes.isNotEmpty) {
          await NotificationHelper.scheduleTaskReminders(
            taskId: updatedTask.id,
            taskTitle: updatedTask.title,
            taskDateTime: taskDateTime,
            reminderMinutes: updatedTask.reminderMinutes,
          );
        }
        if (updatedTask.alarmEnabled && updatedTask.alarmTime != null) {
          await NotificationHelper.scheduleTaskAlarm(
            taskId: updatedTask.id,
            taskTitle: updatedTask.title,
            alarmTime: updatedTask.alarmTime!,
          );
        }
      }
      return;
    }
    if (task.repeatRule.toLowerCase() == 'never') return;

    // Recurring: spawn the next occurrence. State is updated as soon as the
    // DB insert succeeds so a notification failure can never hide the new
    // instance from the UI.
    final regenerated = task.regenerate();

    // Guard against duplicates: un-completing then re-completing (or a
    // double-tap delivering the stale model twice) must not stack identical
    // future occurrences.
    final alreadyExists = _currentTasks.any((t) {
      if (t.id == task.id || t.isDeleted || t.isArchived || t.isCompleted) {
        return false;
      }
      if (t.title != regenerated.title ||
          t.category != regenerated.category ||
          t.repeatRule.toLowerCase() != task.repeatRule.toLowerCase()) {
        return false;
      }
      return DateTime(t.dueDate.year, t.dueDate.month, t.dueDate.day) ==
          DateTime(regenerated.dueDate.year, regenerated.dueDate.month,
              regenerated.dueDate.day);
    });
    if (alreadyExists) return;
    if (!persisted) {
      // The completion itself failed to persist — spawning the next
      // occurrence now would leave an unchecked original plus a phantom clone.
      return;
    }

try {
        _dataRevision++;
        await dbHelper.createTask(regenerated);
      } catch (e) {
      debugPrint('Error regenerating recurring task: $e');
      return;
    }
    _updateState([..._currentTasks, regenerated]);

    if (notificationsEnabled) {
      try {
        final taskDateTime = regenerated.startTime ??
            DateTime(regenerated.dueDate.year, regenerated.dueDate.month,
                regenerated.dueDate.day, 9, 0);
        if (regenerated.reminderMinutes.isNotEmpty) {
          await NotificationHelper.scheduleTaskReminders(
            taskId: regenerated.id,
            taskTitle: regenerated.title,
            taskDateTime: taskDateTime,
            reminderMinutes: regenerated.reminderMinutes,
          );
        }
        if (regenerated.alarmEnabled && regenerated.alarmTime != null) {
          await NotificationHelper.scheduleTaskAlarm(
            taskId: regenerated.id,
            taskTitle: regenerated.title,
            alarmTime: regenerated.alarmTime!,
          );
        }
      } catch (e) {
        debugPrint('Failed to schedule reminders for recurring task: $e');
      }
    }
  }

  Future<void> toggleFavorite(Task task) async {
    await updateTask(task.copyWith(isFavorite: !task.isFavorite));
  }

  Future<void> togglePin(Task task) async {
    await updateTask(task.copyWith(isPinned: !task.isPinned));
  }

  /// Recreates pending notifications for every active (not completed, not
  /// archived, not deleted) task that has reminders. Used on startup and
  /// after the "Task reminders" master switch is turned on.
  Future<void> rescheduleAllTaskReminders() async {
    // Ensure the task list is loaded first (dedupes the notifier's own
    // construction-time load) so reminders are never (re)built from empty
    // state on a cold start.
    await loadTasks();
    // Schedule every task in parallel: zonedSchedule is a platform-channel
    // round-trip, so a serial loop of N tasks serializes N++ round-trips at
    // startup. Concurrent scheduling cuts that wall-clock time dramatically
    // on devices with many reminders.
    final tasks = _currentTasks
        .where((t) => !t.isCompleted && !t.isArchived && !t.isDeleted)
        .toList();
    await Future.wait(tasks.map((task) async {
      try {
        final taskDateTime = task.startTime ??
            DateTime(task.dueDate.year, task.dueDate.month, task.dueDate.day,
                9, 0);
        if (task.reminderMinutes.isNotEmpty) {
          await NotificationHelper.scheduleTaskReminders(
            taskId: task.id,
            taskTitle: task.title,
            taskDateTime: taskDateTime,
            reminderMinutes: task.reminderMinutes,
          );
        }
        // Also reschedule alarm if enabled.
        if (task.alarmEnabled && task.alarmTime != null) {
          await NotificationHelper.scheduleTaskAlarm(
            taskId: task.id,
            taskTitle: task.title,
            alarmTime: task.alarmTime!,
          );
        }
      } catch (e) {
        debugPrint('Failed to reschedule reminders for ${task.id}: $e');
      }
    }));
  }

  /// Withdraws every pending task notification. Used when the "Task
  /// reminders" master switch is turned off.
  Future<void> cancelAllTaskReminders() async {
    final tasks = _currentTasks
        .where((t) =>
            !t.isCompleted &&
            !t.isArchived &&
            !t.isDeleted &&
            t.reminderMinutes.isNotEmpty)
        .toList();
    await Future.wait(tasks.map((task) async {
      try {
        await NotificationHelper.cancelAllForTask(task.id,
            reminderMinutes: task.reminderMinutes);
      } catch (e) {
        debugPrint('Failed to cancel reminders for ${task.id}: $e');
      }
    }));
  }

  Future<void> clearAllTasks() async {
    await _runExclusive(() async {
      try {
        _dataRevision++;
        await dbHelper.clearTasks();
        _updateState([]);
      } catch (e) {
        debugPrint('Error clearing tasks: $e');
      }
    });
  }
}

final allTasksProvider = Provider<List<Task>>((ref) {
  final state = ref.watch(taskProvider);
  return state.maybeWhen(
    data: (tasks) => tasks,
    orElse: () => [],
  );
});

final todayTasksProvider = Provider<List<Task>>((ref) {
  final tasks = ref.watch(allTasksProvider);
  final now = DateTime.now();
  final startOfDay = DateTime(now.year, now.month, now.day);
  final startOfNextDay = DateTime(now.year, now.month, now.day + 1);

  return tasks.where((task) {
    return !task.dueDate.isBefore(startOfDay) &&
        task.dueDate.isBefore(startOfNextDay);
  }).toList();
});

/// Tasks grouped by their local calendar date. Recomputes only when the task
/// list changes — calendar day-taps and rebuilds read this cached map instead
/// of re-scanning every task.
final tasksByDayProvider =
    Provider<Map<int, List<Task>>>((ref) {
  final tasks = ref.watch(allTasksProvider);
  final byDay = <int, List<Task>>{};
  for (final task in tasks) {
    if (task.isDeleted || task.isArchived) continue;
    final key = _dayKey(task.dueDate);
    byDay.putIfAbsent(key, () => []).add(task);
  }
  return byDay;
});

/// Stable integer calendar-day key (`yyyyMMdd`) for a local date. Used by
/// [tasksByDayProvider] so day lookups are a single int hash instead of a
/// fresh DateTime allocation per calendar cell.
int _dayKey(DateTime date) => date.year * 10000 + date.month * 100 + date.day;

final archivedTasksProvider =
    FutureProvider.autoDispose<List<Task>>((ref) async {
  final dbHelper = ref.watch(databaseProvider);
  return dbHelper.getArchivedTasks();
});

final categoriesProvider =
    StateNotifierProvider<CategoriesNotifier, AsyncValue<List<TaskCategory>>>(
        (ref) {
  final dbHelper = ref.watch(databaseProvider);
  return CategoriesNotifier(dbHelper);
});

class CategoriesNotifier extends StateNotifier<AsyncValue<List<TaskCategory>>> {
  final DatabaseHelper dbHelper;
  Future<void>? _appendQueue;

  CategoriesNotifier(this.dbHelper) : super(const AsyncValue.loading()) {
    loadCategories();
  }

  Future<void> loadCategories() async {
    try {
      final categories = await dbHelper.getAllCategories();
      state = AsyncValue.data(categories);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  List<TaskCategory> get _current =>
      state.maybeWhen(data: (c) => c, orElse: () => []);

  bool _nameTaken(String name, {String? exceptId}) =>
      _current.any((c) =>
          c.id != exceptId && c.name.toLowerCase() == name.toLowerCase());

  /// Tasks reference categories BY NAME, so the seeded "Personal" category
  /// must stay stable — it is both the delete fallback and a user expectation.
  static bool _isPersonal(TaskCategory c) =>
      c.name.toLowerCase() == 'personal';

  Future<void> addCategory(TaskCategory category) async {
    final name = category.name.trim();
    if (_nameTaken(name)) {
      throw StateError('A category named "$name" already exists.');
    }
    final run = (_appendQueue ?? Future.value()).then((_) async {
      try {
        await dbHelper.createCategory(category);
        state = AsyncValue.data([..._current, category]);
      } catch (e) {
        debugPrint('Error adding category: $e');
        rethrow;
      }
    });
    _appendQueue = run.catchError((Object e) {
      debugPrint('Append queue error (category): $e');
    });
    return run;
  }

  Future<void> updateCategory(TaskCategory category) async {
    final old = _current.where((c) => c.id == category.id).firstOrNull;
    if (old == null) return;
    final name = category.name.trim();
    if (_nameTaken(name, exceptId: category.id)) {
      throw StateError('A category named "$name" already exists.');
    }
    if (_isPersonal(old) && !_isPersonal(category)) {
      throw StateError('The "Personal" category cannot be renamed.');
    }
    await dbHelper.updateCategory(category);
    // Keep tasks attached when the display name changes.
    if (old.name != name) {
      await dbHelper.reassignTasksCategory(old.name, name);
    }
    final list = _current;
    final index = list.indexWhere((c) => c.id == category.id);
    if (index != -1) {
      final updated = List<TaskCategory>.from(list);
      updated[index] = category;
      state = AsyncValue.data(updated);
    }
  }

  Future<bool> deleteCategory(TaskCategory category) async {
    try {
      // Resolve the fallback dynamically: prefer an existing "Personal",
      // otherwise any other category. Never invent a name that doesn't exist.
      final current = _current;
      TaskCategory? fallback;
      for (final c in current) {
        if (c.id == category.id) continue;
        if (_isPersonal(c)) {
          fallback = c;
          break;
        }
        fallback ??= c;
      }
      if (fallback != null) {
        await dbHelper.reassignTasksCategory(category.name, fallback.name);
      }
      await dbHelper.deleteCategory(category.id);
      state =
          AsyncValue.data(current.where((c) => c.id != category.id).toList());
      return true;
    } catch (e) {
      debugPrint('Error deleting category: $e');
      return false;
    }
  }
}

final habitLogsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, habitId) async {
  final dbHelper = ref.watch(databaseProvider);
  return dbHelper.getHabitLogs(habitId);
});

String habitLogIdFor(String habitId, DateTime date) {
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$habitId-${date.year}-$m-$d';
}

/// Plain 'yyyy-MM-dd' key used by habit_logs and completion history.
String habitDateKey(DateTime date) {
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${date.year}-$m-$d';
}

/// Per-log editable item list. autoDispose keeps notifiers for closed days
/// from accumulating forever, and re-loads fresh from the DB each time a
/// day's sheet is reopened (the sheet is the only writer of these rows).
final habitLogItemsProvider = StateNotifierProvider.autoDispose.family<
    HabitLogItemsNotifier,
    List<HabitLogItem>,
    String>((ref, logId) {
  final dbHelper = ref.watch(databaseProvider);
  return HabitLogItemsNotifier(dbHelper, logId);
});

class HabitLogItemsNotifier extends StateNotifier<List<HabitLogItem>> {
  final DatabaseHelper dbHelper;
  final String logId;

  HabitLogItemsNotifier(this.dbHelper, this.logId) : super(const []) {
    load();
  }

  Future<void> load() async {
    try {
      state = await dbHelper.getHabitLogItems(logId);
    } catch (e) {
      debugPrint('Error loading habit log items: $e');
    }
  }

  Future<void> addItem(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      final item =
          HabitLogItem(logId: logId, text: trimmed, position: state.length);
      await dbHelper.createHabitLogItem(item);
      state = [...state, item];
    } catch (e) {
      debugPrint('Error adding habit log item: $e');
    }
  }

  Future<void> updateItemText(HabitLogItem item, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      final updated = item.copyWith(text: trimmed);
      await dbHelper.updateHabitLogItem(updated);
      state = [
        for (final it in state) if (it.id == item.id) updated else it
      ];
    } catch (e) {
      debugPrint('Error updating habit log item: $e');
    }
  }

  Future<void> deleteItem(HabitLogItem item) async {
    try {
      await dbHelper.deleteHabitLogItem(item.id);
      state = state.where((it) => it.id != item.id).toList();
    } catch (e) {
      debugPrint('Error deleting habit log item: $e');
    }
  }
}

final habitsProvider =
    StateNotifierProvider<HabitNotifier, AsyncValue<List<Habit>>>((ref) {
  final dbHelper = ref.watch(databaseProvider);
  return HabitNotifier(dbHelper);
});

/// Sorted habits for display (by effective streak descending).
final sortedHabitsProvider = Provider<List<Habit>>((ref) {
  final habitsState = ref.watch(habitsProvider);
  final habits = habitsState.maybeWhen(
    data: (items) => items,
    orElse: () => <Habit>[],
  );
  final sorted = List<Habit>.from(habits);
  sorted.sort((a, b) =>
      b.effectiveCurrentStreak().compareTo(a.effectiveCurrentStreak()));
  return sorted;
});

final overallStatsProvider = Provider<Map<String, dynamic>>((ref) {
  final habitsState = ref.watch(habitsProvider);
  final habits = habitsState.maybeWhen(
    data: (items) => items,
    orElse: () => <Habit>[],
  );
  final totalStreaks = habits.length;
  final longestStreak = habits.fold<int>(
    0,
    (previousValue, habit) => habit.bestStreak > previousValue
        ? habit.bestStreak
        : previousValue,
  );
  final averageStreak = totalStreaks == 0
      ? 0.0
      : habits.fold<int>(
              0, (sum, habit) => sum + habit.effectiveCurrentStreak()) /
          totalStreaks;
  final completedToday = habits.where((habit) => habit.isCompletedToday).length;
  final bestStreakEver = habits.fold<int>(
    0,
    (previousValue, habit) =>
        habit.bestStreak > previousValue ? habit.bestStreak : previousValue,
  );

  return {
    'totalStreaks': totalStreaks,
    'longestStreak': longestStreak,
    'averageStreak': averageStreak,
    'completedToday': completedToday,
    'bestStreakEver': bestStreakEver,
  };
});

final streakSummaryProvider = Provider<Map<String, dynamic>>((ref) {
  final habitsState = ref.watch(habitsProvider);
  final habits = habitsState.maybeWhen(
    data: (items) => items,
    orElse: () => <Habit>[],
  );

  final activeStreaks =
      habits.where((habit) => habit.effectiveCurrentStreak() > 0).length;
  final longestStreak = habits.fold<int>(
    0,
    (previousValue, habit) => habit.bestStreak > previousValue
        ? habit.bestStreak
        : previousValue,
  );
  final completedToday = habits.where((habit) => habit.isCompletedToday).length;

  return {
    'activeStreaks': activeStreaks,
    'longestStreak': longestStreak,
    'completedToday': completedToday,
  };
});

class HabitNotifier extends StateNotifier<AsyncValue<List<Habit>>> {
  final DatabaseHelper dbHelper;
  Timer? _midnightTimer;
  Future<void>? _appendQueue;

  HabitNotifier(this.dbHelper) : super(const AsyncValue.loading()) {
    loadHabits();
    _armMidnightReload();
  }

  /// habit.isCompletedToday / streaks are date-dependent; reload at midnight
  /// so they stay correct while the app sits open overnight.
  void _armMidnightReload() {
    _midnightTimer?.cancel();
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer = Timer(nextMidnight.difference(now), () async {
      if (!mounted) return;
      await loadHabits();
      _armMidnightReload();
    });
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  List<Habit> get _currentHabits => state.maybeWhen(
        data: (habits) => habits,
        orElse: () => [],
      );

  void _updateState(List<Habit> habits) {
    state = AsyncValue.data(habits);
    final best = habits.fold<int>(
        0, (max, h) => h.effectiveCurrentStreak() > max
            ? h.effectiveCurrentStreak()
            : max);
    HomeWidgetService.refreshHabits(best, habits: habits);
  }

  Future<void> loadHabits() async {
    try {
      // Keep previous data on re-loads (e.g. midnight rollover, restore) so
      // the Streaks list and dashboard card never blank out mid-session.
      final hasData = state.maybeWhen(data: (_) => true, orElse: () => false);
      if (!hasData) state = const AsyncValue.loading();
      final habits = await dbHelper.getAllHabits();
      _updateState(habits);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> addHabit(Habit habit) async {
    final run = (_appendQueue ?? Future.value()).then((_) async {
      try {
        await dbHelper.createHabit(habit);
        _updateState([habit, ..._currentHabits]);
      } catch (e) {
        debugPrint('Error adding habit: $e');
        rethrow;
      }
    });
    _appendQueue = run.catchError((Object e) {
      debugPrint('Append queue error (habit): $e');
    });
    await run;
  }

  Future<void> updateHabit(Habit habit) async {
    try {
      await dbHelper.updateHabit(habit);
      final habits = _currentHabits;
      final index = habits.indexWhere((h) => h.id == habit.id);
      if (index != -1) {
        final updated = List<Habit>.from(habits);
        updated[index] = habit;
        _updateState(updated);
      }
    } catch (e) {
      debugPrint('Error updating habit: $e');
    }
  }

  Future<void> deleteHabit(String id) async {
    try {
      await dbHelper.deleteHabit(id);
      _updateState(_currentHabits.where((h) => h.id != id).toList());
    } catch (e) {
      debugPrint('Error deleting habit: $e');
    }
  }

  Future<Habit?> completeToday(String habitId, {DateTime? now}) async {
    try {
      final habit = await dbHelper.getHabit(habitId);
      if (habit == null) {
        return null;
      }

      final moment = now ?? DateTime.now();
      final dateKey = habitDateKey(moment);
      final updatedHabit = habit.markCompleted(now: moment);
      await dbHelper.updateHabit(updatedHabit);
      await dbHelper.logHabitCompletion(habitId, dateKey);

      // Reflect the streak in the UI immediately — the snapshot below is
      // auxiliary and must never block or undo this update.
      final habits = _currentHabits;
      final index = habits.indexWhere((h) => h.id == habitId);
      if (index != -1) {
        final updated = List<Habit>.from(habits);
        updated[index] = updatedHabit;
        _updateState(updated);
      }

      // Snapshot this day's checklist into the immutable completion history.
      // Later edits to today's log entries never rewrite previous days.
      try {
        final logItems =
            await dbHelper.getHabitLogItems(habitLogIdFor(habitId, moment));
        if (logItems.isNotEmpty) {
          await dbHelper.saveCompletionChecklist(
            habitId,
            dateKey,
            [
              for (var i = 0; i < logItems.length; i++)
                HabitCompletionItem(
                  habitId: habitId,
                  completionDate: dateKey,
                  text: logItems[i].text,
                  completed: true,
                  position: i,
                ),
            ],
          );
        }
      } catch (e) {
        debugPrint('Failed to snapshot habit checklist: $e');
      }

      return updatedHabit;
    } catch (e) {
      debugPrint('Error logging habit: $e');
      return null;
    }
  }

  /// Re-snapshots a specific day's completion checklist from the live log
  /// entries.
  ///
  /// Called when the user adds/edits/deletes entries after completing, so
  /// "one more time" updates are reflected for the selected day. Other days'
  /// snapshots are never touched.
  Future<void> syncTodaySnapshot(String habitId, {DateTime? now}) async {
    await _syncSnapshotForDate(habitId, now ?? DateTime.now());
  }

  /// Syncs the completion checklist snapshot for an arbitrary date.
  Future<void> _syncSnapshotForDate(String habitId, DateTime date) async {
    try {
      final dateKey = habitDateKey(date);

      final logs = await dbHelper.getHabitLogs(habitId);
      final dayCompleted = logs.any((log) {
        final raw = log['date'];
        return raw is String &&
            raw.length >= 10 &&
            raw.substring(raw.length - 10) == dateKey;
      });
      if (!dayCompleted) return;

      final logItems =
          await dbHelper.getHabitLogItems(habitLogIdFor(habitId, date));
      await dbHelper.saveCompletionChecklist(
        habitId,
        dateKey,
        [
          for (var i = 0; i < logItems.length; i++)
            HabitCompletionItem(
              habitId: habitId,
              completionDate: dateKey,
              text: logItems[i].text,
              completed: true,
              position: i,
            ),
        ],
      );
    } catch (e) {
      debugPrint('Error syncing habit snapshot: $e');
    }
  }

  /// Checks whether a habit was completed on a specific date.
  Future<bool> isCompletedOnDate(String habitId, DateTime date) async {
    final logs = await dbHelper.getHabitLogs(habitId);
    final dateKey = habitDateKey(date);
    return logs.any((log) {
      final raw = log['date'];
      return raw is String &&
          raw.length >= 10 &&
          raw.substring(raw.length - 10) == dateKey;
    });
  }

  /// Recalculates currentStreak and bestStreak from the stored habit_logs
  /// for the given habit, then persists the updated Habit record.
  ///
  /// The streak is the longest run of consecutive days ending at (or just
  /// before) today. 'bestStreak' is the all-time longest consecutive run.
  Future<Habit?> _recalculateStreaks(String habitId) async {
    try {
      final habit = await dbHelper.getHabit(habitId);
      if (habit == null) return null;

      final dates = await dbHelper.getHabitCompletionDates(habitId);
      if (dates.isEmpty) {
        final updatedHabit = habit.copyWith(
          currentStreak: 0,
          bestStreak: 0,
          lastCompletedDate: null,
          updatedAt: DateTime.now(),
        );
        await dbHelper.updateHabit(updatedHabit);
        _updateHabitInState(habitId, updatedHabit);
        return updatedHabit;
      }

      final today = _startOfDay(DateTime.now());
      final yesterday = DateTime(today.year, today.month, today.day - 1);

      // Current streak: consecutive days ending at today or yesterday.
      int currentStreak = 0;
      if (dates.last.isAtSameMomentAs(today) ||
          dates.last.isAtSameMomentAs(yesterday)) {
        // Walk backwards from the latest date.
        currentStreak = 1;
        for (int i = dates.length - 1; i > 0; i--) {
          final diff = _daysBetween(dates[i - 1], dates[i]);
          if (diff == 1) {
            currentStreak++;
          } else {
            break;
          }
        }
      }

      // Best streak: longest consecutive run across all dates, recomputed
      // from the actual completion history.
      int bestStreak = 0;
      int run = 1;
      for (int i = 1; i < dates.length; i++) {
        final diff = _daysBetween(dates[i - 1], dates[i]);
        if (diff == 1) {
          run++;
        } else {
          if (run > bestStreak) bestStreak = run;
          run = 1;
        }
      }
      if (run > bestStreak) bestStreak = run;

      final updated = habit.copyWith(
        currentStreak: currentStreak,
        bestStreak: bestStreak,
        lastCompletedDate: dates.last,
        updatedAt: DateTime.now(),
      );
      await dbHelper.updateHabit(updated);
      _updateHabitInState(habitId, updated);
      return updated;
    } catch (e) {
      debugPrint('Error recalculating streaks: $e');
      return null;
    }
  }

  static DateTime _startOfDay(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  /// Calendar-day difference (DST-safe): compares date-only components as UTC
  /// so a spring-forward/fall-back shift can never fold two consecutive days
  /// into a "0-day" or "2-day" gap.
  static int _daysBetween(DateTime a, DateTime b) {
    final ua = DateTime.utc(a.year, a.month, a.day);
    final ub = DateTime.utc(b.year, b.month, b.day);
    return ub.difference(ua).inDays;
  }

  /// Marks [date] as completed for [habitId] (historical streak control).
  ///
  /// If the date already has a completion record, this is a no-op.
  /// After marking, streaks are recalculated from stored history.
  Future<void> markHabitDate(String habitId, DateTime date) async {
    try {
      final dateKey = habitDateKey(date);

      // Idempotent: skip if already completed.
      final already = await isCompletedOnDate(habitId, date);
      if (already) return;

      await dbHelper.logHabitCompletion(habitId, dateKey);
      await _recalculateStreaks(habitId);
      // Rebuild the day's completion snapshot from the (persisted) log items
      // so the day-sheet and the complete-sheet keep showing the same data
      // after a manual mark / unmark / remark cycle.
      await _syncSnapshotForDate(habitId, date);
    } catch (e) {
      debugPrint('Error marking habit date: $e');
    }
  }

  /// Removes the completion record for [date] on [habitId]
  /// (historical miss-streak control).
  ///
  /// After removal, streaks are recalculated from stored history.
  Future<void> unmarkHabitDate(String habitId, DateTime date) async {
    try {
      final dateKey = habitDateKey(date);
      await dbHelper.removeHabitCompletion(habitId, dateKey);
      await _recalculateStreaks(habitId);
      // Clear the day's snapshot too so unmarked days show "No checklist
      // recorded" instead of stale items.
      await dbHelper.saveCompletionChecklist(habitId, dateKey, []);
    } catch (e) {
      debugPrint('Error unmarking habit date: $e');
    }
  }

  /// Updates a single habit in the current state list without reloading
  /// the entire collection.
  void _updateHabitInState(String habitId, Habit updated) {
    final habits = _currentHabits;
    final index = habits.indexWhere((h) => h.id == habitId);
    if (index != -1) {
      final list = List<Habit>.from(habits);
      list[index] = updated;
      _updateState(list);
    }
  }
}
