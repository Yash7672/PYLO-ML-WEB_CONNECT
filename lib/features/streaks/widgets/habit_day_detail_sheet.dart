import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/undo_snackbar.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../models/habit_completion_item.dart';
import '../../../models/habit_model.dart';
import '../../../providers/database_provider.dart';
import '../../../providers/task_provider.dart';
import '../../../theme/app_theme.dart';

Color _hairlineBorder(BuildContext context) => isGlassTheme(context)
    ? GlassColors.borderStrong
    : Colors.grey.shade300;

/// Bottom sheet shown when tapping any date on the streak history calendar.
/// Shows status and streak/miss controls for historical dates, plus the
/// completion checklist for completed dates.
Future<void> showHabitDayDetailSheet(
  BuildContext context,
  WidgetRef ref,
  Habit habit,
  DateTime day,
) {
  final dateOnly = DateTime(day.year, day.month, day.day);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _HabitDayDetailSheet(habit: habit, day: dateOnly),
  );
}

class _HabitDayDetailSheet extends ConsumerStatefulWidget {
  final Habit habit;
  final DateTime day;

  const _HabitDayDetailSheet({required this.habit, required this.day});

  @override
  ConsumerState<_HabitDayDetailSheet> createState() =>
      _HabitDayDetailSheetState();
}

class _HabitDayDetailSheetState extends ConsumerState<_HabitDayDetailSheet> {
  late List<HabitCompletionItem> _items;
  bool _isLoading = true;
  bool _isCompleted = false;
  bool _isProcessing = false;
  final _addController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  String get _dateKey {
    final m = widget.day.month.toString().padLeft(2, '0');
    final d = widget.day.day.toString().padLeft(2, '0');
    return '${widget.day.year}-$m-$d';
  }

  bool get _isToday {
    final now = DateTime.now();
    return widget.day.year == now.year &&
        widget.day.month == now.month &&
        widget.day.day == now.day;
  }

  Future<void> _loadItems() async {
    try {
      if (!mounted) return;
      final dbHelper = ref.read(databaseProvider);
      final notifier = ref.read(habitsProvider.notifier);
      // Both queries are independent — run them concurrently instead of
      // serially so the sheet opens as soon as the slower one completes.
      final results = await Future.wait([
        dbHelper.getCompletionChecklist(widget.habit.id, _dateKey),
        notifier.isCompletedOnDate(widget.habit.id, widget.day),
      ]);
      if (!mounted) return;
      setState(() {
        _items = results[0] as List<HabitCompletionItem>;
        _isCompleted = results[1] as bool;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading day details: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _markAsStreak() async {
    if (_isProcessing) return;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(habitsProvider.notifier);
    setState(() => _isProcessing = true);
    await notifier.markHabitDate(widget.habit.id, widget.day);
    if (!mounted) return;
    await _loadItems();
    if (!mounted) return;
    setState(() => _isProcessing = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Marked as streak for ${DateFormat('d MMM yyyy').format(widget.day)}',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.green.shade800,
      ),
    );
  }

  Future<void> _markAsMiss() async {
    if (_isProcessing) return;
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(habitsProvider.notifier);
    setState(() => _isProcessing = true);
    final snapshot =
        await notifier.unmarkHabitDateForUndo(widget.habit.id, widget.day);
    if (!mounted) return;
    await _loadItems();
    if (!mounted) return;
    setState(() => _isProcessing = false);
    if (snapshot == null) return;
    showDeleteUndoSnackBar<HabitUnmarkSnapshot>(
      messenger,
      message:
          'Removed streak for ${DateFormat('d MMM yyyy').format(widget.day)}',
      backup: snapshot,
      onUndo: (kept) => notifier.restoreUnmarkedDay(kept),
    );
  }

  Future<void> _addItem() async {
    final text = _addController.text.trim();
    if (text.isEmpty) return;

    final item = HabitCompletionItem(
      habitId: widget.habit.id,
      completionDate: _dateKey,
      text: text,
      completed: true,
      position: _items.length,
    );

    final dbHelper = ref.read(databaseProvider);
    try {
      await dbHelper.addCompletionItem(item);
      if (!mounted) return;
      _addController.clear();
      if (!mounted) return;
      await _loadItems();
    } catch (e) {
      debugPrint('Error adding item: $e');
    }
  }

  Future<void> _editItem(HabitCompletionItem item) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _EditItemDialog(initialText: item.text),
    );
    if (result != null && result.trim().isNotEmpty && result.trim() != item.text) {
      if (!mounted) return;
      final dbHelper = ref.read(databaseProvider);
      try {
        await dbHelper.updateCompletionItem(
          item.copyWith(text: result.trim()),
        );
        if (!mounted) return;
        await _loadItems();
      } catch (e) {
        debugPrint('Error updating item: $e');
      }
    }
  }

  Future<void> _deleteItem(HabitCompletionItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text('Remove "${item.text}" from this day?'),
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
      if (!mounted) return;
      final dbHelper = ref.read(databaseProvider);
      final row = item.toMap();
      try {
        await dbHelper.deleteCompletionItem(item.id);
        if (!mounted) return;
        await _loadItems();
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        showDeleteUndoSnackBar<Map<String, dynamic>>(
          messenger,
          message: 'Item deleted',
          backup: row,
          onUndo: (kept) async {
            await dbHelper
                .addCompletionItem(HabitCompletionItem.fromMap(kept));
            if (mounted) await _loadItems();
          },
        );
      } catch (e) {
        debugPrint('Error deleting item: $e');
      }
    }
  }

  Future<void> _toggleItem(HabitCompletionItem item) async {
    final dbHelper = ref.read(databaseProvider);
    await dbHelper.updateCompletionItem(
      item.copyWith(completed: !item.completed),
    );
    if (!mounted) return;
    await _loadItems();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──
              Row(
                children: [
                  _isCompleted
                    ? const Text('🔥', style: TextStyle(fontSize: 22))
                    : const Icon(Icons.event, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('d MMMM yyyy').format(widget.day),
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          widget.habit.name,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: glassSecondaryText(context)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // ── Status badge ──
              _StatusBadge(isCompleted: _isCompleted),

              const SizedBox(height: 12),

              // ── Streak / Miss controls ──
              if (_isProcessing)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isCompleted ? null : _markAsStreak,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('✓ Streak'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.green,
                          side: BorderSide(
                            color: _isCompleted
                                ? _hairlineBorder(context)
                                : Colors.green,
                          ),
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: !_isCompleted ? null : _markAsMiss,
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('✕ Miss Streak'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: BorderSide(
                            color: !_isCompleted
                                ? _hairlineBorder(context)
                                : Colors.red,
                          ),
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

              const SizedBox(height: 16),

              // ── Checklist section (only for completed dates) ──
              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_isCompleted) ...[                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No checklist recorded for this day.',
                        style: TextStyle(
                            color: glassSecondaryText(context), fontSize: 14),
                      ),
                    )
                else
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          return _CompletionTile(
                            item: item,
                            onToggle: () => _toggleItem(item),
                            onEdit: () => _editItem(item),
                            onDelete: () => _deleteItem(item),
                          );
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addController,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Add checklist item…',
                          prefixIcon: const Icon(Icons.add_task_rounded),
                          isDense: true,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        onSubmitted: (_) => _addItem(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _addItem,
                      icon: const Icon(Icons.add),
                      tooltip: 'Add item',
                    ),
                  ],
                ),
              ] else ...[
                // Not completed — show a note
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _isToday
                        ? 'Not completed today. Use the Streak button above to mark it, or complete from the habit card.'
                        : 'Not completed on this day. Use the Streak button above to mark it manually.',
                    style: TextStyle(
                        color: glassSecondaryText(context), fontSize: 14),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the completion status of the selected date.
class _StatusBadge extends StatelessWidget {
  final bool isCompleted;

  const _StatusBadge({required this.isCompleted});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isCompleted ? Colors.green : Colors.orange;
    // Dark literal shades (green.shade700 etc.) vanish on dark surfaces; pick
    // a readable shade per brightness for the text and border.
    final shade = isDark ? base.shade300 : base.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: shade,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCompleted ? Icons.check_circle : Icons.cancel_outlined,
            size: 18,
            color: base,
          ),
          const SizedBox(width: 8),
          Text(
            isCompleted ? '✓ Streak' : '✕ Missed',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: shade,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompletionTile extends StatelessWidget {
  final HabitCompletionItem item;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CompletionTile({
    required this.item,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = item.completed
        ? Colors.green
        : (isGlassTheme(context)
            ? GlassColors.textMuted
            : Colors.grey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: onToggle,
            child: Icon(
              item.completed
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              size: 22,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.text,
              style: TextStyle(
                fontSize: 15,
                decoration:
                    item.completed ? null : TextDecoration.lineThrough,
                color: item.completed
                    ? Theme.of(context).colorScheme.onSurface
                    : glassSecondaryText(context),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Edit',
            onPressed: onEdit,
          ),
          IconButton(
            icon: Icon(Icons.delete_outline,
                size: 18, color: Colors.red.shade400),
            tooltip: 'Delete',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Edit-item dialog that owns its own [TextEditingController]. This keeps the
/// controller lifecycle attached to the dialog route (not the bottom sheet)
/// so dismissing the sheet while the dialog is open can never leave a
/// disposed controller behind, and the sheet's state survives cleanly.
class _EditItemDialog extends StatefulWidget {
  const _EditItemDialog({required this.initialText});

  final String initialText;

  @override
  State<_EditItemDialog> createState() => _EditItemDialogState();
}

class _EditItemDialogState extends State<_EditItemDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit item'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Item text'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
