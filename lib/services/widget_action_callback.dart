import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../database/database_helper.dart';
import 'home_widget_service.dart';

/// Top-level entry point for the home_widget background interactivity callback.
///
/// When the user taps a widget checkbox, the broadcast receiver wakes this
/// callback in a headless Dart isolate. The callback toggles the task in the
/// local SQLite DB and pushes the updated Today Tasks widget data so the
/// checkbox state updates instantly — even when the app is not in the foreground.
///
/// Registered once at startup in [registerWidgetCallback].
@pragma('vm:entry-point')
Future<void> onWidgetTaskAction(Uri? uri) async {
  if (uri == null) return;
  if (uri.host != 'complete_task') return;

  final taskId = uri.queryParameters['id'];
  if (taskId == null || taskId.isEmpty) return;

  try {
    final db = DatabaseHelper.instance;
    try {
      final allTasks = await db.getAllTasks();

      final taskIndex = allTasks.indexWhere((t) => t.id == taskId);
      if (taskIndex == -1) return;

      final task = allTasks[taskIndex];
      final toggled = task.copyWith(isCompleted: !task.isCompleted);
      await db.updateTask(toggled);

      // A task completed from the widget must not keep ringing its alarm or
      // firing its reminders. The notification and AlarmManager plugins are
      // not registered in this headless isolate, so the cancel is QUEUED and
      // performed by the main isolate on the next launch/resume (see
      // main.dart → _drainPendingWidgetAlarmCancels).
      if (toggled.isCompleted) {
        await HomeWidgetService.queueAlarmCancel(toggled.id);
      }

      // Mutate the already-fetched list in place so the widget push avoids a
      // second full-table scan right after the write.
      allTasks[taskIndex] = toggled;
      await HomeWidgetService.refreshTodayTasksWidget(allTasks);
    } finally {
      // This headless isolate opened its own connection to the same DB file.
      // Close it so the file handle is never leaked between widget taps and
      // the next tap reopens it cleanly.
      await db.close();
    }
  } catch (e) {
    debugPrint('onWidgetTaskAction failed: $e');
  }
}

/// Registers the interactivity callback with the home_widget plugin.
/// Safe to call multiple times; idempotent.
void registerWidgetCallback() {
  HomeWidget.registerInteractivityCallback(onWidgetTaskAction);
}
