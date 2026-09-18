import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/undo_manager.dart';
import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../models/habit_model.dart';
import '../../../providers/task_provider.dart';
import '../../../theme/app_theme.dart';
import 'habit_complete_sheet.dart';
import 'habit_detail_popup.dart';

Color _mutedControl(BuildContext context) =>
    isGlassTheme(context) ? GlassColors.textMuted : Colors.grey;

class HabitCard extends ConsumerWidget {
  final Habit habit;

  const HabitCard({
    super.key,
    required this.habit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One "now" for the whole card so streak/date math is consistent and
    // DateTime.now() isn't called once per method.
    final now = DateTime.now();
    final isCompletedToday = habit.isCompletedOnDate(now);
    final effectiveStreak = habit.effectiveCurrentStreak(now: now);
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _showDetailPopup(context, habit),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header: icon + name + status badge ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isCompletedToday
                          ? Colors.green.withValues(alpha: 0.12)
                          : theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.5),
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                    ),
                    child: Icon(
                      Icons.local_fire_department,
                      color: isCompletedToday ? Colors.green : Colors.orange,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          habit.name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (habit.description.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            habit.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: glassMutedText(context)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isCompletedToday
                          ? Colors.green
                          : Colors.transparent,
                      borderRadius: const BorderRadius.all(Radius.circular(20)),
                      border: isCompletedToday
                          ? null
                          : Border.all(
                              color: isGlassTheme(context)
                                  ? GlassColors.borderStrong
                                  : Colors.grey.withValues(alpha: 0.4),
                              width: 1,
                            ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isCompletedToday
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 14,
                          color: isCompletedToday
                              ? Colors.white
                              : glassMutedText(context),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isCompletedToday ? 'COMPLETED' : 'PENDING',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isCompletedToday
                                ? Colors.white
                                : glassMutedText(context),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // ── Streak info ──
              Row(
                children: [
                  Expanded(
                    child: _InfoTile(
                      icon: Icons.local_fire_department,
                      label: 'Current Streak',
                      value: '$effectiveStreak Days',
                      color: effectiveStreak > 0
                          ? Colors.orange
                          : _mutedControl(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _InfoTile(
                      icon: Icons.emoji_events_outlined,
                      label: 'Best Streak',
                      value: '${habit.bestStreak} Days',
                      color: Colors.amber,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // ── Last completed ──
              Row(
                children: [
                  Icon(Icons.calendar_today_outlined,
                      size: 14, color: glassMutedText(context)),
                  const SizedBox(width: 6),
                  Text(
                    'Last Completed: ${habit.getLastCompletedLabel(referenceDate: now)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: glassMutedText(context)),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // ── Actions ──
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          showHabitCompleteSheet(context, ref, habit),
                      icon: Icon(
                        isCompletedToday ? Icons.check_circle : Icons.check,
                        size: 18,
                      ),
                      label: Text(
                        isCompletedToday ? 'Completed Today' : 'Complete Today',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: isCompletedToday
                            ? (isGlassTheme(context)
                                ? GlassColors.level2
                                : Colors.grey.withValues(alpha: 0.25))
                            : Colors.green,
                        foregroundColor: isCompletedToday
                            ? (isGlassTheme(context)
                                ? GlassColors.textMuted
                                : Colors.grey[600])
                            : Colors.white,
                        minimumSize: const Size.fromHeight(42),
shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () =>
                        _showEditHabitDialog(context, ref, habit),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'Edit',
                    style: IconButton.styleFrom(
                      foregroundColor: glassMutedText(context),
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        _showDeleteConfirmation(context, ref, habit),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Delete',
                    style: IconButton.styleFrom(
                      foregroundColor: Colors.red[400],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetailPopup(BuildContext context, Habit habit) {
    showDialog(
      context: context,
      builder: (context) => HabitDetailPopup(habit: habit),
    );
  }

  Future<void> _showEditHabitDialog(
      BuildContext context, WidgetRef ref, Habit habit) async {
    final messenger = ScaffoldMessenger.of(context);
    final nameController = TextEditingController(text: habit.name);
    final descriptionController =
        TextEditingController(text: habit.description);

    final result = await showDialog<Habit>(
      context: context,
      builder: (context) => DisposeOnExit(
        controllers: [nameController, descriptionController],
        child: AlertDialog(
          title: const Text('Edit Streak'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Streak Name',
                  prefixIcon: Icon(Icons.local_fire_department),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  prefixIcon: Icon(Icons.description_outlined),
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (nameController.text.trim().isNotEmpty) {
                  Navigator.pop(
                    context,
                    habit.copyWith(
                      name: nameController.text.trim(),
                      description: descriptionController.text.trim(),
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      await ref.read(habitsProvider.notifier).updateHabit(result);
      messenger.showSnackBar(
        const SnackBar(content: Text('Streak updated!')),
      );
    }
  }

  Future<void> _showDeleteConfirmation(
      BuildContext context, WidgetRef ref, Habit habit) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Streak?'),
        content: const Text(
            'The streak, its history and completion checklist will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      // Capture the notifier NOW — deleting unmounts this card before Undo is
      // tapped, and reading `ref` from the unmounted card throws
      // `StateError: Cannot use "ref" after the widget was disposed` from
      // inside the SnackBar's onTap — aborting the restore.
      final habitNotifier = ref.read(habitsProvider.notifier);
      deleteWithUndo<HabitDeleteSnapshot>(
        messenger,
        message: 'Streak deleted',
        performDelete: () => habitNotifier.deleteHabitForUndo(habit),
        undo: (kept) => habitNotifier.restoreHabit(kept),
      );
    }
  }
}

// ── Info tile used for streak stats ──

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: glassMutedText(context),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
