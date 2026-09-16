import '../../database/database_helper.dart';
import '../../models/checklist_model.dart';
import '../../models/task_model.dart';

/// A snapshot of everything the user needs to see on the future PYLO website
/// for one calendar day. Mirrors the `daily_data` table columns:
///
///   tasks    -> today's tasks (with their embedded task checklists)
///   lists    -> standalone quick checklists
///   sublists -> every checklist item (inside today's tasks AND standalone)
class DailyCloudData {
  final String dateKey;
  final List<Map<String, dynamic>> tasks;
  final List<Map<String, dynamic>> lists;
  final List<Map<String, dynamic>> sublists;

  const DailyCloudData({
    required this.dateKey,
    required this.tasks,
    required this.lists,
    required this.sublists,
  });
}

/// Local calendar day in PostgreSQL-compatible `YYYY-MM-DD` form.
///
/// Deliberately derived from the device's local date (never UTC): an Indian
/// user must not land on yesterday/tomorrow's cloud row just because UTC is a
/// different calendar day.
String localDateKey(DateTime date) {
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${date.year}-$m-$d';
}

/// Builds today's cloud snapshot straight from SQLite (the local source of
/// truth). Local-only / device-private fields (alarm sound file URIs,
/// vibration / snooze settings, reminder scheduling details) are intentionally
/// left out of the payload.
Future<DailyCloudData> buildTodayCloudData(
  DatabaseHelper db,
  DateTime now,
) async {
  final today = DateTime(now.year, now.month, now.day);

  final tasks = await db.getTasksByDate(today);
  final checklists = await db.getAllChecklists();
  final checklistItems = await db.getAllChecklistItems();

  final taskPayload = <Map<String, dynamic>>[];
  final listPayload = <Map<String, dynamic>>[];
  final sublistPayload = <Map<String, dynamic>>[];

  for (final task in tasks) {
    taskPayload.add(taskToCloudMap(task));
    final embedded = task.checklist;
    for (var i = 0; i < embedded.length; i++) {
      final item = embedded[i];
      sublistPayload.add({
        'id': '${task.id}:$i',
        'source': 'task',
        'parentId': task.id,
        'text': item.text,
        'completed': item.done,
        'position': i,
      });
    }
  }

  for (final list in checklists) {
    listPayload.add(checklistToCloudMap(list));
    for (final item in checklistItems[list.id] ?? const <ChecklistItem>[]) {
      sublistPayload.add({
        'id': item.id,
        'source': 'checklist',
        'parentId': item.checklistId,
        'text': item.text,
        'completed': item.completed,
        'position': item.position,
      });
    }
  }

  return DailyCloudData(
    dateKey: localDateKey(now),
    tasks: taskPayload,
    lists: listPayload,
    sublists: sublistPayload,
  );
}

/// Cloud representation of a [Task]. Timestamps are epoch milliseconds (the
/// same unit the local SQLite schema already uses) so the website can render
/// them with `new Date(ms)` without any timezone ambiguity.
///
/// Excluded because they are device-private / local-only:
/// alarmSound, alarmSoundType, alarmSoundUri, snoozeDuration, vibrationEnabled,
/// reminderMinutes.
Map<String, dynamic> taskToCloudMap(Task task) => {
      'id': task.id,
      'title': task.title,
      'description': task.description,
      'category': task.category,
      'priority': task.priority,
      'dueDate': task.dueDate.millisecondsSinceEpoch,
      'startTime': task.startTime?.millisecondsSinceEpoch,
      'endTime': task.endTime?.millisecondsSinceEpoch,
      'isCompleted': task.isCompleted,
      'isArchived': task.isArchived,
      'isDeleted': task.isDeleted,
      'isFavorite': task.isFavorite,
      'isPinned': task.isPinned,
      'notes': task.notes,
      'repeatRule': task.repeatRule,
      'repeatMonthday': task.repeatMonthday,
      'color': task.color,
      'estimatedDuration': task.estimatedDuration,
      'alarmEnabled': task.alarmEnabled,
      'alarmTime': task.alarmTime?.millisecondsSinceEpoch,
      'completedAt': task.completedAt?.millisecondsSinceEpoch,
      'createdAt': task.createdAt.millisecondsSinceEpoch,
      'updatedAt': task.updatedAt.millisecondsSinceEpoch,
      'checklist': task.checklist
          .map((item) => {'text': item.text, 'done': item.done})
          .toList(),
    };

/// Cloud representation of a standalone [Checklist].
Map<String, dynamic> checklistToCloudMap(Checklist checklist) => {
      'id': checklist.id,
      'title': checklist.title,
      'createdAt': checklist.createdAt.millisecondsSinceEpoch,
      'updatedAt': checklist.updatedAt.millisecondsSinceEpoch,
    };