import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/undo_snackbar.dart';
import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../models/birthday_model.dart';
import '../../../providers/birthday_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../theme/app_theme.dart';
import '../widgets/birthday_card.dart';

class BirthdaysScreen extends ConsumerWidget {
  const BirthdaysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(birthdayProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Birthdays')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'birthdays_fab',
        onPressed: () => _showBirthdayDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add Birthday'),
      ),
      body: state.when(
        data: (birthdays) {
          if (birthdays.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.pink.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.cake_rounded,
                          size: 48, color: Colors.pink),
                    ),
                    const SizedBox(height: 20),
                    Text('No birthdays yet',
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      'Add birthdays once — PYLO reminds you every year.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: isGlassTheme(context)
                              ? GlassColors.textSecondary
                              : Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
            itemCount: birthdays.length,
            itemBuilder: (context, index) => BirthdayCard(
              birthday: birthdays[index],
              onEdit: () => _showBirthdayDialog(context, ref,
                  birthday: birthdays[index]),
              onDelete: () => _confirmDelete(context, ref, birthdays[index]),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
      ),
    );
  }

  Future<void> _showBirthdayDialog(BuildContext context, WidgetRef ref,
      {Birthday? birthday}) async {
    final nameController = TextEditingController(text: birthday?.name ?? '');
    final phoneController = TextEditingController(text: birthday?.phone ?? '');
    final notesController = TextEditingController(text: birthday?.notes ?? '');
    DateTime? selectedDate = birthday?.birthDate;
    List<int> selectedReminders =
        birthday != null ? List.from(birthday.reminderDaysBefore) : [0];
    int reminderHour = birthday?.reminderHour ?? 9;
    int reminderMinute = birthday?.reminderMinute ?? 0;
    final notificationsEnabled =
        ref.read(settingsPreferencesProvider).birthdayRemindersEnabled;
    String? validationError;

    final controllers = [nameController, phoneController, notesController];

    final result = await showDialog<Birthday>(
      context: context,
      builder: (dialogContext) => DisposeOnExit(
        controllers: controllers,
        child: StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(birthday == null ? 'Add Birthday' : 'Edit Birthday'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                      labelText: 'Name',
                      prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cake_outlined),
                  title: const Text('Birthday'),
                  subtitle: Text(selectedDate == null
                      ? 'Select date'
                      : '${selectedDate!.day} ${_monthName(selectedDate!.month)} ${selectedDate!.year}'),
                  onTap: () async {
                    final initial = selectedDate ?? DateTime.now();
                    final picked = await showDatePicker(
                      context: dialogContext,
                      initialDate: initial.isAfter(DateTime.now())
                          ? DateTime.now()
                          : initial,
                      firstDate: DateTime(1900),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      setDialogState(() {
                        selectedDate = picked;
                        validationError = null;
                      });
                    }
                  },
                ),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'Phone (optional)',
                      prefixIcon: Icon(Icons.phone_outlined)),
                ),
                TextField(
                  controller: notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                      labelText: 'Notes (optional)'),
                ),
                const SizedBox(height: 16),
                Text('Remind me',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [0, 1, 3, 7].map((days) {
                    final selected = selectedReminders.contains(days);
                    return FilterChip(
                      label: Text(switch (days) {
                        0 => 'On day',
                        1 => '1 day before',
                        3 => '3 days',
                        _ => '7 days',
                      }),
                      selected: selected,
                      onSelected: (val) {
                        setDialogState(() {
                          if (val) {
                            selectedReminders.add(days);
                          } else {
                            selectedReminders.remove(days);
                          }
                          validationError = null;
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Text('Reminder time',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.access_time),
                  title: Text(
                    DateFormat('hh:mm a').format(
                        DateTime(2024, 1, 1, reminderHour, reminderMinute)),
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: dialogContext,
                      initialTime: TimeOfDay(
                          hour: reminderHour, minute: reminderMinute),
                    );
                    if (picked != null) {
                      setDialogState(() {
                        reminderHour = picked.hour;
                        reminderMinute = picked.minute;
                      });
                    }
                  },
                ),
                if (validationError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      validationError!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) {
                  setDialogState(() => validationError = 'Name is required.');
                  return;
                }
                final pickedDate = selectedDate;
                if (pickedDate == null) {
                  setDialogState(() => validationError = 'Date is required.');
                  return;
                }
                if (selectedReminders.isEmpty) {
                  setDialogState(() =>
                      validationError = 'Select at least one reminder.');
                  return;
                }
                // Duplicate guard: same (case-insensitive) name AND same
                // birth date already exists — excludes the entry being edited.
                final existing = ref
                    .read(birthdayProvider)
                    .maybeWhen(data: (list) => list, orElse: () => <Birthday>[]);
                final duplicate = existing.any((b) {
                  if (birthday != null && b.id == birthday.id) return false;
                  return b.name.trim().toLowerCase() ==
                          nameController.text.trim().toLowerCase() &&
                      b.birthDate.month == pickedDate.month &&
                      b.birthDate.day == pickedDate.day;
                });
                if (duplicate) {
                  setDialogState(() =>
                      validationError = 'A birthday for this person on this '
                          'date already exists.');
                  return;
                }
                Navigator.pop(
                  context,
                  Birthday(
                    id: birthday?.id,
                    name: nameController.text.trim(),
                    birthDate: pickedDate,
                    phone: phoneController.text.trim(),
                    notes: notesController.text.trim(),
                    reminderDaysBefore: selectedReminders..sort(),
                    reminderHour: reminderHour,
                    reminderMinute: reminderMinute,
                    createdAt: birthday?.createdAt,
                  ),
                );
              },
              child: Text(birthday == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
      ),
    );

    if (result == null) return;
    final notifier = ref.read(birthdayProvider.notifier);
    if (birthday == null) {
      await notifier.addBirthday(result,
          notificationsEnabled: notificationsEnabled);
    } else {
      await notifier.updateBirthday(result,
          notificationsEnabled: notificationsEnabled);
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, Birthday birthday) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete birthday?'),
        content: Text('Remove ${birthday.name} from your reminders?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      if (!context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final row = await ref
          .read(birthdayProvider.notifier)
          .deleteBirthdayForUndo(birthday);
      if (row == null) return;
      showDeleteUndoSnackBar<Map<String, dynamic>>(
        messenger,
        message: 'Birthday deleted',
        backup: row,
        onUndo: (kept) => ref
            .read(birthdayProvider.notifier)
            .restoreBirthday(kept, notificationsEnabled: true),
      );
    }
  }

  String _monthName(int month) => switch (month) {
        1 => 'January', 2 => 'February', 3 => 'March', 4 => 'April',
        5 => 'May', 6 => 'June', 7 => 'July', 8 => 'August',
        9 => 'September', 10 => 'October', 11 => 'November', _ => 'December',
      };
}
