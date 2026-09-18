import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/notification_helper.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../models/task_model.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/task_provider.dart';
import '../../../theme/app_theme.dart';

class AddEditTaskScreen extends ConsumerStatefulWidget {
  final Task? taskToEdit;

  const AddEditTaskScreen({super.key, this.taskToEdit});

  @override
  ConsumerState<AddEditTaskScreen> createState() => _AddEditTaskScreenState();
}

class _AddEditTaskScreenState extends ConsumerState<AddEditTaskScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _titleController;
  late TextEditingController _descController;
  late TextEditingController _checklistController;

  String _selectedCategory = 'Personal';
  String _selectedPriority = 'Medium';
  String _repeatRule = 'Never';
  DateTime _dueDate = DateTime.now();
  DateTime? _startTime;
  List<int> _selectedReminders = [];
  List<ChecklistItemData> _checklist = [];
  bool _alarmEnabled = false;
  DateTime? _alarmTime;
  int? _repeatMonthday;

  final List<String> _priorities = [
    'Critical',
    'High',
    'Medium',
    'Low',
    'No Priority'
  ];
  final List<String> _repeatRules = [
    'Never',
    'Daily',
    'Weekly',
    'Monthly',
    'Yearly'
  ];
  final List<int> _reminderOptions = [1, 5, 10, 15, 30, 60, 120, 180, 1440];

  /// Guards against double-fire of _saveTask (rapid double-tap on the
  /// Create/Update button) which would write the task twice and duplicate
  /// every reminder notification.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: widget.taskToEdit?.title ?? '');
    _descController =
        TextEditingController(text: widget.taskToEdit?.description ?? '');
    _checklistController = TextEditingController();
    if (widget.taskToEdit != null) {
      _selectedCategory = widget.taskToEdit!.category;
      _selectedPriority = widget.taskToEdit!.priority;
      _repeatRule = widget.taskToEdit!.repeatRule;
      _dueDate = widget.taskToEdit!.dueDate;
      _startTime = widget.taskToEdit!.startTime;
      _selectedReminders = List<int>.from(widget.taskToEdit!.reminderMinutes);
      _checklist = List<ChecklistItemData>.from(widget.taskToEdit!.checklist);
      _alarmEnabled = widget.taskToEdit!.alarmEnabled;
      _alarmTime = widget.taskToEdit!.alarmTime;
      // Preserve the original day-of-month anchor instead of assuming the
      // current due date's day. Otherwise editing a monthly/yearly task that
      // was rescheduled (e.g. to Feb 28) silently re-anchors recurrence.
      _repeatMonthday = widget.taskToEdit!.repeatMonthday;
    } else {
      _selectedReminders = List<int>.from(
          ref.read(settingsPreferencesProvider).reminderMinutes);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _checklistController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _dueDate = picked;
        // The user explicitly re-chose the date, so re-anchor recurrence to
        // the newly picked day-of-month.
        _repeatMonthday = picked.day;
        // Re-anchor the chosen start time onto the newly picked date so the
        // task never silently slides to yesterday/another date.
        if (_startTime != null) {
          _startTime = DateTime(picked.year, picked.month, picked.day,
              _startTime!.hour, _startTime!.minute);
        }
      });
    }
  }

  Future<void> _pickStartTime() async {
    final initialTime = TimeOfDay.fromDateTime(_startTime ?? DateTime.now());
    final picked =
        await showTimePicker(context: context, initialTime: initialTime);
    if (picked != null && mounted) {
      setState(() {
        _startTime = DateTime(_dueDate.year, _dueDate.month, _dueDate.day,
            picked.hour, picked.minute);
      });
    }
  }

  void _addChecklistItem() {
    final item = _checklistController.text.trim();
    if (item.isEmpty) return;
    setState(() {
      _checklist.add(ChecklistItemData(text: item));
      _checklistController.clear();
    });
  }

  Future<void> _saveTask() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    _saving = true;
    try {
      final isEditingCompleted = widget.taskToEdit?.isCompleted ?? false;
      final hasReminders = _selectedReminders.isNotEmpty &&
          ref.read(settingsPreferencesProvider).notificationsEnabled;
      final task = Task(
        id: widget.taskToEdit?.id,
        title: _titleController.text.trim(),
        description: _descController.text.trim(),
        category: _selectedCategory,
        priority: _selectedPriority,
        dueDate: _dueDate,
        startTime: _startTime,
        endTime: null,
        notes: '',
        repeatRule: _repeatRule,
        checklist: _checklist,
        reminderMinutes: _selectedReminders,
        estimatedDuration: '',
        alarmEnabled: _alarmEnabled,
        alarmTime: _alarmEnabled ? _alarmTime : null,
        isCompleted: widget.taskToEdit?.isCompleted ?? false,
        isArchived: widget.taskToEdit?.isArchived ?? false,
        isDeleted: widget.taskToEdit?.isDeleted ?? false,
        isFavorite: widget.taskToEdit?.isFavorite ?? false,
        isPinned: widget.taskToEdit?.isPinned ?? false,
        snoozeDuration: widget.taskToEdit?.snoozeDuration ?? 5,
        vibrationEnabled: widget.taskToEdit?.vibrationEnabled ?? true,
        completedAt: widget.taskToEdit?.completedAt,
        createdAt: widget.taskToEdit?.createdAt,
        color: widget.taskToEdit?.color ?? '',
        // Anchor used by monthly/yearly recurrence so rescheduling the task
        // never drifts off the originally chosen day-of-month.
        repeatMonthday: _repeatMonthday ?? _dueDate.day,
      );

      if (widget.taskToEdit != null) {
        // Cancel both the previously-saved and the newly-selected offsets so
        // a reminder the user just removed can never keep firing.
        await NotificationHelper.cancelAllForTask(
          task.id,
          reminderMinutes: [
            ...?widget.taskToEdit?.reminderMinutes,
            ..._selectedReminders,
          ],
        );
        await ref.read(taskProvider.notifier).updateTask(task);
      } else {
        await ref.read(taskProvider.notifier).addTask(task);
      }

      // Ask for exact-alarm access at the moment a reminder/alarm is actually
      // being armed (never at plugin init), so the system screen is contextual
      // instead of a surprise on first launch.
      if ((hasReminders || (_alarmEnabled && _alarmTime != null)) &&
          !isEditingCompleted) {
        await NotificationHelper.requestExactAlarmAccess();
      }

      // A task that was already completed (e.g. its title/due date being
      // corrected after completion) must NOT re-arm its reminders.
      if (hasReminders && !isEditingCompleted) {
        final taskDateTime = _startTime ??
            DateTime(_dueDate.year, _dueDate.month, _dueDate.day, 9, 0);
        await NotificationHelper.scheduleTaskReminders(
          taskId: task.id,
          taskTitle: task.title,
          taskDateTime: taskDateTime,
          reminderMinutes: _selectedReminders,
        );
      }
      if (_alarmEnabled && _alarmTime != null && !isEditingCompleted) {
        await NotificationHelper.scheduleTaskAlarm(
          taskId: task.id,
          taskTitle: task.title,
          alarmTime: _alarmTime!,
        );
      }

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Error saving task: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Could not save task',
              style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.red.shade800,
        ));
      }
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesState = ref.watch(categoriesProvider);
    final categoryNames = categoriesState.maybeWhen(
      data: (categories) =>
          categories.map((c) => c.name).toList(),
      orElse: () => <String>[],
    );
    final effectiveCategory =
        categoryNames.contains(_selectedCategory) || _selectedCategory.isEmpty
            ? _selectedCategory
            : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.taskToEdit == null ? 'Add Task' : 'Edit Task'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Task Title',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val == null || val.trim().isEmpty
                    ? 'Please enter a title'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description (Optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Category', border: OutlineInputBorder()),
                      child: DropdownButton<String>(
                        value: effectiveCategory,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        items: categoryNames
                            .map(
                                (c) => DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedCategory = val);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Priority', border: OutlineInputBorder()),
                      child: DropdownButton<String>(
                        value: _selectedPriority,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        items: _priorities
                            .map(
                                (p) => DropdownMenuItem(value: p, child: Text(p)))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedPriority = val);
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Repeat Rule', border: OutlineInputBorder()),
                child: DropdownButton<String>(
                  value: _repeatRule,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: _repeatRules
                      .map((rule) =>
                          DropdownMenuItem(value: rule, child: Text(rule)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _repeatRule = val);
                  },
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Due Date'),
                subtitle: Text(
                    '${_dueDate.year}-${_dueDate.month.toString().padLeft(2, '0')}-${_dueDate.day.toString().padLeft(2, '0')}'),
                trailing: const Icon(Icons.calendar_today),
                onTap: _pickDate,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start Time'),
                subtitle: Text(_startTime == null
                    ? 'Not set'
                    : '${_startTime!.hour.toString().padLeft(2, '0')}:${_startTime!.minute.toString().padLeft(2, '0')}'),
                trailing: const Icon(Icons.access_time),
                onTap: () => _pickStartTime(),
              ),
              const SizedBox(height: 12),
              Text('Reminders (before task)',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _reminderOptions.map((minutes) {
                  final isSelected = _selectedReminders.contains(minutes);
                  final label = switch (minutes) {
                    1 => '1 min',
                    5 => '5 min',
                    10 => '10 min',
                    15 => '15 min',
                    30 => '30 min',
                    60 => '1 hr',
                    120 => '2 hr',
                    180 => '3 hr',
                    1440 => '1 day',
                    _ => '$minutes min',
                  };
                  return FilterChip(
                    label: Text(label),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedReminders.add(minutes);
                          _selectedReminders.sort();
                        } else {
                          _selectedReminders.remove(minutes);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.access_time, size: 20),
                title: const Text('Remind at a specific time',
                    style: TextStyle(fontSize: 14)),
                subtitle: const Text('Pick a clock time for the reminder',
                    style: TextStyle(fontSize: 12)),
                onTap: () async {
                  final taskDateTime = _startTime ??
                      DateTime(_dueDate.year, _dueDate.month, _dueDate.day, 9, 0);
                   final picked = await showTimePicker(
                     context: context,
                     initialTime: TimeOfDay.fromDateTime(taskDateTime),
                   );
                   if (!mounted) return;
                    if (picked != null) {
                     final reminderTime = DateTime(
                       _dueDate.year, _dueDate.month, _dueDate.day,
                       picked.hour, picked.minute,
                     );
                     final diff = taskDateTime.difference(reminderTime).inMinutes;
                     if (diff > 0 && !_selectedReminders.contains(diff)) {
                       setState(() {
                         _selectedReminders.add(diff);
                         _selectedReminders.sort();
                       });
                       } else if (diff <= 0) {
                          if (!context.mounted) return;
ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                         content: const Text('Reminder time must be before the task start time',
                             style: TextStyle(color: Colors.white)),
                         backgroundColor: Colors.orange.shade900,
                       ));
                     }
                   }
                },
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Alarm'),
                subtitle: const Text('Play an alarm at a specific time'),
                secondary: const Icon(Icons.alarm),
                value: _alarmEnabled,
                onChanged: (val) {
                  setState(() {
                    _alarmEnabled = val;
                    if (val && _alarmTime == null) {
                      final base = _startTime ??
                          DateTime(
                              _dueDate.year, _dueDate.month, _dueDate.day, 9, 0);
                      _alarmTime = base;
                    }
                  });
                },
              ),
              if (_alarmEnabled)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Alarm Time'),
                  subtitle: Text(_alarmTime == null
                      ? 'Not set'
                      : '${_alarmTime!.hour.toString().padLeft(2, '0')}:${_alarmTime!.minute.toString().padLeft(2, '0')}'),
                  trailing: const Icon(Icons.access_time),
                  onTap: () async {
                    final taskDateTime = _startTime ??
                        DateTime(
                            _dueDate.year, _dueDate.month, _dueDate.day, 9, 0);
                    final picked = await showTimePicker(
                      context: context,
                      initialTime:
                          TimeOfDay.fromDateTime(_alarmTime ?? taskDateTime),
                    );
                    if (picked != null && mounted) {
                      setState(() {
                        _alarmTime = DateTime(
                          _dueDate.year,
                          _dueDate.month,
                          _dueDate.day,
                          picked.hour,
                          picked.minute,
                        );
                      });
                    }
                  },
                ),
              const SizedBox(height: 12),
              Text('Checklist',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _checklistController,
                      decoration: const InputDecoration(
                          labelText: 'Checklist Item',
                          border: OutlineInputBorder()),
                      onSubmitted: (_) => _addChecklistItem(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: _addChecklistItem, child: const Text('Add')),
                ],
              ),
              const SizedBox(height: 8),
              if (_checklist.isNotEmpty)
                Column(
                  children: [
                    for (var i = 0; i < _checklist.length; i++)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _checklist[i].done,
                        title: Text(
                          _checklist[i].text,
                          style: TextStyle(
                            decoration: _checklist[i].done
                                ? TextDecoration.lineThrough
                                : null,
                            color: _checklist[i].done
                                ? (isGlassTheme(context)
                                    ? GlassColors.textMuted
                                    : Colors.grey)
                                : null,
                          ),
                        ),
                        onChanged: (val) {
                          setState(() =>
                              _checklist[i] = _checklist[i].copyWith(done: val ?? false));
                        },
                        secondary: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () =>
                              setState(() => _checklist.removeAt(i)),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _saveTask,
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16)),
                child: Text(
                    widget.taskToEdit == null ? 'Create Task' : 'Update Task',
                    style: const TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
