import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_app/database/database_helper.dart';
import 'package:task_app/features/dashboard/widgets/task_list_item.dart';
import 'package:task_app/features/streaks/widgets/habit_card.dart';
import 'package:task_app/models/habit_model.dart';
import 'package:task_app/models/task_model.dart';
import 'package:task_app/providers/database_provider.dart';
import 'package:task_app/providers/preferences_provider.dart';
import 'package:task_app/providers/task_provider.dart';

// Mirrors the dashboard: the list is driven by provider state, so an item is
// unmounted the moment its delete removes it — exactly the real app.
class TaskHost extends ConsumerWidget {
  const TaskHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref
        .watch(taskProvider)
        .maybeWhen(data: (t) => t, orElse: () => const <Task>[]);
    return ListView(
      children: [
        for (final t in tasks) TaskListItem(key: ValueKey(t.id), task: t),
      ],
    );
  }
}

class HabitHost extends ConsumerWidget {
  const HabitHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final habits = ref
        .watch(habitsProvider)
        .maybeWhen(data: (h) => h, orElse: () => const <Habit>[]);
    return ListView(
      children: [
        for (final h in habits) HabitCard(key: ValueKey(h.id), habit: h),
      ],
    );
  }
}

Widget buildApp({required Widget child}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(DatabaseHelper.instance),
      settingsPreferencesProvider.overrideWith((ref) {
        final notifier = SettingsPreferencesNotifier();
        notifier.state = notifier.state.copyWith(notificationsEnabled: false);
        return notifier;
      }),
    ],
    child: MaterialApp(
      home: Scaffold(body: child),
    ),
  );
}

Task makeTask({required String id}) {
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
  );
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final dbsPath = await databaseFactory.getDatabasesPath();
    await Directory(dbsPath).create(recursive: true);
    DatabaseHelper.testDbPathOverride =
        p.join(dbsPath, 'taskflow_undo_widget_test.db');
  });

  setUp(() async {
    final path = await DatabaseHelper.instance.databasePath;
    await databaseFactory.deleteDatabase(path);
    await DatabaseHelper.instance.initDatabase();
  });

  tearDown(() async {
    await DatabaseHelper.instance.close();
  });

  testWidgets('task swipe-delete then Undo restores without throwing',
      (tester) async {
    final task = makeTask(id: 'w1');
    await DatabaseHelper.instance.createTask(task);

    await tester.pumpWidget(buildApp(child: const TaskHost()));
    await tester.pumpAndSettle();
    expect(find.byType(TaskListItem), findsOneWidget);

    // Swipe the task away like a user would.
    await tester.drag(find.byType(Dismissible), const Offset(-800, 0));
    await tester.pumpAndSettle();

    expect(find.text('Task deleted'), findsOneWidget);
    expect(find.byType(TaskListItem), findsNothing);

    // The TaskListItem was unmounted by the delete; tapping Undo must still
    // restore it and must NOT throw "Cannot use ref after the widget was
    // disposed" from inside the onTap gesture handler.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(TaskListItem), findsOneWidget);
    expect(await DatabaseHelper.instance.getTask('w1'), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('habit delete then Undo restores without throwing',
      (tester) async {
    final habit = Habit(id: 'h1', name: 'Morning Run');
    await DatabaseHelper.instance.createHabit(habit);

    await tester.pumpWidget(buildApp(child: const HabitHost()));
    await tester.pumpAndSettle();
    expect(find.byType(HabitCard), findsOneWidget);

    // Delete via the card's trash button, confirm the dialog.
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Streak deleted'), findsOneWidget);
    expect(find.byType(HabitCard), findsNothing);

    // HabitCard was unmounted by the delete; tapping Undo must still restore
    // it and must NOT throw from inside the onTap gesture handler.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(HabitCard), findsOneWidget);
    expect(await DatabaseHelper.instance.getHabit('h1'), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}