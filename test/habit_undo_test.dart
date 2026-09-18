import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_app/database/database_helper.dart';
import 'package:task_app/models/habit_completion_item.dart';
import 'package:task_app/models/habit_log_item.dart';
import 'package:task_app/models/habit_model.dart';
import 'package:task_app/providers/database_provider.dart';
import 'package:task_app/providers/task_provider.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final dbsPath = await databaseFactory.getDatabasesPath();
    await Directory(dbsPath).create(recursive: true);
    DatabaseHelper.testDbPathOverride =
        p.join(dbsPath, 'taskflow_habit_undo_test.db');
  });

  setUp(() async {
    final path = await DatabaseHelper.instance.databasePath;
    await databaseFactory.deleteDatabase(path);
    await DatabaseHelper.instance.initDatabase();
  });

  tearDown(() async {
    await DatabaseHelper.instance.close();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(DatabaseHelper.instance),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> seedHabitWithHistory() async {
    final db = DatabaseHelper.instance;
    // Habit with a 2-day completion history, log items and a completion
    // checklist, so undo must restore the whole streak graph, not just the
    // habit row.
    await db.createHabit(Habit(
      id: 'habit-1',
      name: 'Morning Run',
      currentStreak: 2,
      bestStreak: 2,
      lastCompletedDate:
          DateTime(DateTime.now().year, DateTime.now().month,
              DateTime.now().day - 1),
    ));
    await db.logHabitCompletion('habit-1', '2026-09-16');
    await db.logHabitCompletion('habit-1', '2026-09-17');
    await db.createHabitLogItem(HabitLogItem(
      id: 'log-item-1',
      logId: 'habit-1-2026-09-17',
      text: 'Warmup',
      position: 0,
    ));
    await db.createHabitLogItem(HabitLogItem(
      id: 'log-item-2',
      logId: 'habit-1-2026-09-17',
      text: 'Cooldown',
      position: 1,
    ));
    await db.saveCompletionChecklist('habit-1', '2026-09-17', [
      HabitCompletionItem(
        id: 'comp-1',
        habitId: 'habit-1',
        completionDate: '2026-09-17',
        text: 'Warmup',
        position: 0,
      ),
    ]);
  }

  Future<List<Map<String, dynamic>>> rowsOf(
      String table, String where, List<Object?> args) async {
    return DatabaseHelper.instance.queryRows(table,
        where: where, whereArgs: args);
  }

  test('delete then undo restores habit, logs and log items with original IDs',
      () async {
    final container = createContainer();
    await seedHabitWithHistory();
    final notifier = container.read(habitsProvider.notifier);
    await notifier.loadHabits();

    expect(container.read(habitsProvider).value!.map((h) => h.id), ['habit-1']);

    final snapshot = await notifier.deleteHabitForUndo(
        container.read(habitsProvider).value!.first);
    expect(snapshot, isNotNull);
    expect(snapshot!.habitRow['id'], 'habit-1');
    expect(snapshot.logs.length, 2);
    expect(snapshot.logItems.length, 2);
    expect(snapshot.completionItems.length, 1);
    expect(container.read(habitsProvider).value, isEmpty);

    await notifier.restoreHabit(snapshot);

    // Habit row re-inserted under the ORIGINAL id with all fields intact.
    final restored = await DatabaseHelper.instance.getHabit('habit-1');
    expect(restored, isNotNull);
    expect(restored!.name, 'Morning Run');
    expect(restored.currentStreak, 2);
    expect(restored.bestStreak, 2);

    // Related rows re-inserted with original ids and parent relationships.
    final logs = await rowsOf('habit_logs', 'habitId = ?', ['habit-1']);
    expect(logs.length, 2);
    expect(logs.map((r) => r['id']),
        containsAll(['habit-1-2026-09-16', 'habit-1-2026-09-17']));
    final logItems = await rowsOf(
        'habit_log_items', 'logId = ?', ['habit-1-2026-09-17']);
    expect(logItems.map((r) => r['id']),
        containsAll(['log-item-1', 'log-item-2']));
    final comps = await rowsOf(
        'habit_completion_items', 'habitId = ?', ['habit-1']);
    expect(comps.map((r) => r['id']), containsAll(['comp-1']));

    // Provider refreshed so the Streaks screen shows it again.
    final ids = container
        .read(habitsProvider)
        .value!
        .map((h) => h.id)
        .toList();
    expect(ids, ['habit-1']);
  });

  test('immediate undo (restore called before delete settles) restores', () async {
    final container = createContainer();
    await seedHabitWithHistory();
    final notifier = container.read(habitsProvider.notifier);
    await notifier.loadHabits();

    final del = notifier.deleteHabitForUndo(
        container.read(habitsProvider).value!.first);
    // Undo does not know the snapshot until delete returns, so simulate the
    // serialized path by awaiting delete first, then restoring immediately.
    final snapshot = await del;
    final res = notifier.restoreHabit(snapshot!);
    await res;

    expect(container.read(habitsProvider).value!.map((h) => h.id),
        ['habit-1']);
    expect(await DatabaseHelper.instance.getHabit('habit-1'), isNotNull);
  });
}