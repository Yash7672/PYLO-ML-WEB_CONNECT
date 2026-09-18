import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_app/database/database_helper.dart';
import 'package:task_app/models/task_model.dart';
import 'package:task_app/providers/database_provider.dart';
import 'package:task_app/providers/task_provider.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final dbsPath = await databaseFactory.getDatabasesPath();
    await Directory(dbsPath).create(recursive: true);
    DatabaseHelper.testDbPathOverride =
        p.join(dbsPath, 'taskflow_undo_snapshot_test.db');
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

  Task makeTask({String? id}) {
    return Task(
      id: id,
      title: 'Study DAA',
      description: 'Chapter 4',
      category: 'College',
      priority: 'High',
      dueDate: DateTime(2026, 9, 6, 18, 0),
      reminderMinutes: const [10],
      isFavorite: true,
      isPinned: true,
      repeatRule: 'Never',
      checklist: const [
        ChecklistItemData(text: 'DP', done: true),
        ChecklistItemData(text: 'Graphs'),
      ],
    );
  }

  Future<void> seed(Task task) async {
    await DatabaseHelper.instance.createTask(task);
  }

  List<Task> uiTasks(ProviderContainer c) =>
      c.read(taskProvider).maybeWhen(data: (t) => t, orElse: () => []);

  Future<void> settle(ProviderContainer c) async {
    await c.read(taskProvider.notifier).loadTasks();
  }

  test('swipe delete then undo restores the same task incl. its checklist',
      () async {
    final container = createContainer();
    final task = makeTask(id: 't1');
    await seed(task);
    await settle(container);

    expect(uiTasks(container).map((t) => t.id), ['t1']);

    final notifier = container.read(taskProvider.notifier);
    final snapshot = await notifier.deleteTaskForUndo(task);
    expect(snapshot, isNotNull);
    expect(snapshot!.taskRow['id'], 't1');
    // Row is truly gone from the tasks table (hard delete, like Lists/Habits).
    expect(await DatabaseHelper.instance.getTask('t1'), isNull);
    expect(uiTasks(container), isEmpty);

    final restored = await notifier.restoreTaskFromSnapshot(snapshot);
    expect(restored, isNotNull);
    expect(restored!.id, 't1');
    expect(restored.title, 'Study DAA');
    expect(restored.checklist.length, 2);
    expect(restored.checklist[0].text, 'DP');
    expect(restored.checklist[0].done, isTrue);
    expect(restored.reminderMinutes, [10]);
    expect(restored.isFavorite, isTrue);
    expect(restored.isPinned, isTrue);

    final dbCheck = await DatabaseHelper.instance.getTask('t1');
    expect(dbCheck, isNotNull);
    expect(dbCheck!.isDeleted, isFalse);
    expect(dbCheck.isArchived, isFalse);

    expect(uiTasks(container).map((t) => t.id), ['t1']);
  });

  test('immediate undo after swipe delete still restores', () async {
    final container = createContainer();
    final task = makeTask(id: 't2');
    await seed(task);
    await settle(container);

    final notifier = container.read(taskProvider.notifier);
    final del = notifier.deleteTaskForUndo(task);
    final snapshot = await del;
    final res = notifier.restoreTaskFromSnapshot(snapshot!);
    await Future.wait([res]);

    expect(uiTasks(container).map((t) => t.id), ['t2']);
    expect(await DatabaseHelper.instance.getTask('t2'), isNotNull);
  });

  test('snapshot delete then undo does not duplicate the task', () async {
    final container = createContainer();
    final task = makeTask(id: 't3');
    await seed(task);
    await settle(container);

    final notifier = container.read(taskProvider.notifier);
    final snapshot = await notifier.deleteTaskForUndo(task);
    await notifier.restoreTaskFromSnapshot(snapshot!);
    await notifier.restoreTaskFromSnapshot(snapshot); // duplicate undo tap
    await notifier.loadTasks();

    final ids =
        (await DatabaseHelper.instance.getAllTasks()).map((t) => t.id).toList();
    expect(ids.where((id) => id == 't3').length, 1);
  });
}