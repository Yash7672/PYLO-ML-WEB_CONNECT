import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/utils/notification_helper.dart';
import '../../../core/utils/undo_manager.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../features/tasks/screens/add_edit_task_screen.dart';
import '../../../models/task_model.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/task_provider.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/extensions.dart';

Color _mutedIcon(BuildContext context) =>
    isGlassTheme(context)
        ? GlassColors.textMuted
        : Colors.grey;

class TaskListItem extends ConsumerWidget {
  final Task task;

  const TaskListItem({super.key, required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final priorityColor = AppColors.getPriorityColor(task.priority);
    final categoryColor = AppColors.getCategoryColor(task.category);
    final messenger = ScaffoldMessenger.of(context);

    return Dismissible(
      key: Key(task.id),
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        // Capture the notifier + notification flag NOW, not inside the Undo
        // callback flow: swipe-delete unmounts this TaskListItem before the
        // user taps Undo, and reading `ref` from an unmounted consumer throws
        // `StateError: Cannot use "ref" after the widget was disposed` from
        // inside the SnackBar's onTap — aborting the restore.
        final taskNotifier = ref.read(taskProvider.notifier);
        final notificationsEnabled =
            ref.read(settingsPreferencesProvider).notificationsEnabled;
        deleteWithUndo<TaskDeleteSnapshot>(
          messenger,
          message: 'Task deleted',
          performDelete: () => taskNotifier.deleteTaskForUndo(task),
          undo: (snapshot) async {
            final restored =
                await taskNotifier.restoreTaskFromSnapshot(snapshot);
            if (restored != null && notificationsEnabled) {
              _scheduleReminderIfNeeded(restored);
            }
          },
        );
      },
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
            children: [
              Container(
                width: 5,
                height: 96,
                decoration: BoxDecoration(
                  color: priorityColor,
                  borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      bottomLeft: Radius.circular(16)),
                ),
              ),
              Expanded(
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: Transform.scale(
                    scale: 1.2,
                    child: Checkbox(
                      value: task.isCompleted,
                      shape: const CircleBorder(),
                      activeColor: theme.colorScheme.primary,
                      onChanged: (_) => ref
                          .read(taskProvider.notifier)
                          .toggleTaskCompletion(
                            task,
                            notificationsEnabled: ref
                                .read(settingsPreferencesProvider)
                                .notificationsEnabled,
                          ),
                    ),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            decoration: task.isCompleted
                                ? TextDecoration.lineThrough
                                : null,
                            color: task.isCompleted
                                    ? _mutedIcon(context)
                                    : null,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (task.isPinned)
                        const Icon(Icons.push_pin,
                            size: 16, color: Colors.orange),
                      if (task.isFavorite)
                        const Icon(Icons.star, size: 16, color: Colors.amber),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (task.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            task.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: task.isCompleted
                                    ? glassMutedText(context)
                                    : glassSecondaryText(context)),
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: categoryColor.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              task.category,
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: categoryColor,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.calendar_today,
                              size: 12, color: glassMutedText(context)),
                          const SizedBox(width: 4),
                          Text(task.dueDate.toDisplayString(),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: glassMutedText(context))),
                          if (task.alarmEnabled && task.alarmTime != null) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.alarm,
                                size: 12, color: Colors.deepOrange),
                            const SizedBox(width: 2),
                            Text(
                              _alarmTimeLabel(task.alarmTime!),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: Colors.deepOrange),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) async {
                      switch (value) {
                        case 'favorite':
                          ref.read(taskProvider.notifier).toggleFavorite(task);
                          break;
                        case 'pin':
                          ref.read(taskProvider.notifier).togglePin(task);
                          break;
                        case 'archive':
                          ref.read(taskProvider.notifier).archiveTask(task.id);
                          break;
                        case 'restore':
                          await ref
                              .read(taskProvider.notifier)
                              .restoreTaskFromModel(task);
                          if (ref
                              .read(settingsPreferencesProvider)
                              .notificationsEnabled) {
                            await NotificationHelper.cancelAllForTask(
                                task.id,
                                reminderMinutes: task.reminderMinutes);
                            _scheduleReminderIfNeeded(task);
                          }
                          break;
                        case 'delete':
                          _confirmPermanentDelete(context, task, ref);
                          break;
                        default:
                          break;
                      }
                    },
                    itemBuilder: (context) {
                      final items = <PopupMenuEntry<String>>[];
                      items.add(PopupMenuItem(
                          value: 'favorite',
                          child: Text(task.isFavorite
                              ? 'Remove favorite'
                              : 'Favorite')));
                      items.add(PopupMenuItem(
                          value: 'pin',
                          child: Text(task.isPinned ? 'Unpin' : 'Pin')));
                      if (task.isArchived || task.isDeleted) {
                        items.add(const PopupMenuItem(
                            value: 'restore', child: Text('Restore')));
                        items.add(const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete permanently')));
                      } else {
                        items.add(const PopupMenuItem(
                            value: 'archive', child: Text('Archive')));
                      }
                      return items;
                    },
                  ),
                  onTap: () {
                    _showTaskDetails(context, task, ref);
                  },
                ),
              ),
            ],
          ),
        ),
      );
  }

  void _scheduleReminderIfNeeded(Task task) {
    final taskDateTime = task.startTime ??
        DateTime(task.dueDate.year, task.dueDate.month, task.dueDate.day, 9, 0);
    if (task.reminderMinutes.isNotEmpty) {
      NotificationHelper.scheduleTaskReminders(
        taskId: task.id,
        taskTitle: task.title,
        taskDateTime: taskDateTime,
        reminderMinutes: task.reminderMinutes,
      );
    }
    if (task.alarmEnabled && task.alarmTime != null) {
      NotificationHelper.scheduleTaskAlarm(
        taskId: task.id,
        taskTitle: task.title,
        alarmTime: task.alarmTime!,
      );
    }
  }

  String _alarmTimeLabel(DateTime alarmTime) {
    final h = alarmTime.hour.toString().padLeft(2, '0');
    final m = alarmTime.minute.toString().padLeft(2, '0');
    final day = DateTime(alarmTime.year, alarmTime.month, alarmTime.day);
    final today = DateTime.now();
    final t = DateTime(today.year, today.month, today.day);
    final delta = day.difference(t).inDays;
    final when = switch (delta) {
      0 => 'Today',
      1 => 'Tomorrow',
      _ =>
        '${alarmTime.day}/${alarmTime.month}',
    };
    return '$when $h:$m';
  }

  Future<void> _confirmPermanentDelete(
      BuildContext context, Task task, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      ref.read(taskProvider.notifier).deleteTaskPermanently(task.id);
    }
  }

  Future<void> _showTaskDetails(
      BuildContext context, Task task, WidgetRef ref) async {
    final theme = Theme.of(context);
    final priorityColor = AppColors.getPriorityColor(task.priority);
    final categoryColor = AppColors.getCategoryColor(task.category);

    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(task.title,
                            style: theme.textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: priorityColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (task.description.isNotEmpty)
                    Text(task.description,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(color: glassSecondaryText(context))),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Chip(
                        label: Text(task.category),
                        backgroundColor: categoryColor.withValues(alpha: 0.15),
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(task.dueDate.toDisplayString()),
                        backgroundColor: theme.colorScheme.primaryContainer,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Checklist',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (task.checklist.isEmpty)
                    Text('No checklist items.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: glassSecondaryText(context)))
                  else
                    Column(
                      children: task.checklist
                          .map((item) => ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  item.done
                                      ? Icons.check_circle
                                      : Icons.check_circle_outline,
                                  color: item.done
                                      ? theme.colorScheme.primary
                                      : _mutedIcon(context),
                                ),
                                title: Text(
                                  item.text,
                                  style: TextStyle(
                                    decoration: item.done
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color: item.done
                                        ? _mutedIcon(context)
                                        : null,
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          // Resolve the navigator once so the push uses the
                          // same route stack after the sheet pops, instead of
                          // reaching for a context that is being deactivated.
                          final navigator = Navigator.of(context);
                          navigator.pop();
                          navigator.push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  AddEditTaskScreen(taskToEdit: task),
                            ),
                          );
                        },
                        child: const Text('Edit'),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
