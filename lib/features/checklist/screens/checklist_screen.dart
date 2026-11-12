import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/undo_manager.dart';
import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../models/checklist_model.dart';
import '../../../providers/checklist_provider.dart';
import '../widgets/checklist_item.dart';
import '../widgets/move_arrows.dart';

/// Visual feedback while a row is being dragged: the row lifts off the
/// surface (drop shadow) and scales up slightly so it is always obvious which
/// item is moving. It exists only for the duration of a drag — the resting
/// design, colours and layout are untouched.
Widget dragRowProxy(Widget child, int index, Animation<double> animation) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = Curves.easeOutCubic.transform(animation.value);
      return Material(
        color: Colors.transparent,
        elevation: 8 * t,
        shadowColor: Colors.black45,
        child: Transform.scale(
          scale: 1.0 + 0.02 * t,
          alignment: Alignment.center,
          child: child,
        ),
      );
    },
  );
}

class ChecklistScreen extends ConsumerWidget {
  const ChecklistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(checklistProvider);
    final theme = Theme.of(context);

    // Precompute per-checklist totals once per build instead of scanning every
    // item list again for every row during itemBuilder (O(items) not
    // O(rows × items)).
    final totals = <String, (int, int)>{};
    for (final checklist in state.checklists) {
      final items = state.items[checklist.id] ?? const <ChecklistItem>[];
      var done = 0;
      for (final item in items) {
        if (item.completed) done++;
      }
      totals[checklist.id] = (done, items.length);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Checklists')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'checklist_fab',
        onPressed: () => _showCreateDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New List'),
      ),
      body: state.checklists.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.checklist_rounded,
                          size: 48, color: theme.colorScheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: 20),
                    Text('No checklists yet',
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      'Create simple lists like shopping or packing.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: glassSecondaryText(context)),
                    ),
                  ],
                ),
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: state.checklists.length,
              // Long-press + drag reorders the parent list; the whole group
              // (its sublists) moves with it because items are keyed by the
              // parent's id.
              onReorderItem: (oldIndex, newIndex) => ref
                  .read(checklistProvider.notifier)
                  .reorderChecklists(oldIndex, newIndex),
              proxyDecorator: dragRowProxy,
              itemBuilder: (context, index) {
                final checklist = state.checklists[index];
                final (done, total) =
                    totals[checklist.id] ?? const (0, 0);
                return Card(
                  key: ValueKey(checklist.id),
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    leading: CircleAvatar(
                      backgroundColor:
                          theme.colorScheme.primaryContainer,
                      child: Text('$done/$total',
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer)),
                    ),
                    title: Text(checklist.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: total == 0
                        ? const Text('Empty list')
                        : LinearProgressIndicator(
                            value: total == 0 ? 0 : done / total,
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(2),
                          ),
                    // The existing menu is untouched; the compact ↑ / ↓ pair
                    // sits immediately to its right so a list can be
                    // reordered one step at a time without dragging.
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'rename') {
                              _showRenameDialog(context, ref, checklist);
                            } else if (value == 'delete') {
                              _confirmDelete(context, ref, checklist);
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                        MoveArrows(
                          // First row has nothing above it to move into;
                          // last row has nothing below it.
                          canMoveUp: index > 0,
                          canMoveDown: index < state.checklists.length - 1,
                          onMoveUp: () => ref
                              .read(checklistProvider.notifier)
                              .reorderChecklists(index, index - 1),
                          onMoveDown: () => ref
                              .read(checklistProvider.notifier)
                              .reorderChecklists(index, index + 1),
                        ),
                      ],
                    ),
                    onTap: () => _openDetail(context, checklist),
                  ),
                );
              },
            ),
    );
  }

  void _openDetail(BuildContext context, Checklist checklist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChecklistDetailScreen(checklist: checklist),
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => DisposeOnExit(
        controllers: [controller],
        child: AlertDialog(
          title: const Text('New Checklist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'List name (e.g. Shopping)'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Create')),
          ],
        ),
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      await ref.read(checklistProvider.notifier).createChecklist(result.trim());
    }
  }

  Future<void> _showRenameDialog(
      BuildContext context, WidgetRef ref, Checklist checklist) async {
    final controller = TextEditingController(text: checklist.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => DisposeOnExit(
        controllers: [controller],
        child: AlertDialog(
          title: const Text('Rename Checklist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      await ref
          .read(checklistProvider.notifier)
          .renameChecklist(checklist, result.trim());
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, Checklist checklist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete checklist?'),
        content: Text('"${checklist.title}" and all its items will be removed.'),
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
      deleteWithUndo<ChecklistDeleteSnapshot>(
        messenger,
        message: 'Checklist deleted',
        performDelete: () => ref
            .read(checklistProvider.notifier)
            .deleteChecklistForUndo(checklist),
        undo: (kept) =>
            ref.read(checklistProvider.notifier).restoreChecklist(kept),
      );
    }
  }
}

class ChecklistDetailScreen extends ConsumerStatefulWidget {
  final Checklist checklist;

  const ChecklistDetailScreen({super.key, required this.checklist});

  @override
  ConsumerState<ChecklistDetailScreen> createState() =>
      _ChecklistDetailScreenState();
}

class _ChecklistDetailScreenState extends ConsumerState<ChecklistDetailScreen> {
  final _itemController = TextEditingController();

  @override
  void dispose() {
    _itemController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch only THIS checklist's item list so toggling items in another
    // checklist (or renaming any checklist) never rebuilds this screen.
    final items = ref.watch(
      checklistProvider.select(
        (s) => s.items[widget.checklist.id] ?? const <ChecklistItem>[],
      ),
    );
    final pending = items.where((i) => !i.completed).length;

    return Scaffold(
      appBar: AppBar(title: Text(widget.checklist.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Text('$pending left',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: glassSecondaryText(context),
                        fontWeight: FontWeight.w500)),
                const Spacer(),
                if (items.any((i) => i.completed))
                  TextButton.icon(
                    onPressed: () => _clearCompleted(items),
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('Clear done'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text('Add your first item below.',
                        style: TextStyle(color: glassSecondaryText(context))))
                : ReorderableListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: items.length,
                    // Scoped to THIS checklist's id only: a drag can reorder
                    // rows inside this list but can never move an item into
                    // another parent list.
                    onReorderItem: (oldIndex, newIndex) => ref
                        .read(checklistProvider.notifier)
                        .reorderItems(widget.checklist.id, oldIndex, newIndex),
                    proxyDecorator: dragRowProxy,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ChecklistItemTile(
                        key: ValueKey(item.id),
                        item: item,
                        index: index,
                        itemCount: items.length,
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _itemController,
                      decoration: const InputDecoration(
                        hintText: 'Add item…',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addItem(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _addItem,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addItem() {
    final text = _itemController.text.trim();
    if (text.isEmpty) return;
    ref.read(checklistProvider.notifier).addItem(widget.checklist.id, text);
    _itemController.clear();
  }

  void _clearCompleted(List<ChecklistItem> items) {
    final completed = items.where((i) => i.completed).toList();
    if (completed.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    deleteWithUndo<List<Map<String, dynamic>>>(
      messenger,
      message:
          'Cleared ${completed.length} completed item${completed.length == 1 ? '' : 's'}',
      // Capture a DB snapshot for each deleted row so Undo restores the exact
      // persisted data instead of the stale in-memory copy.
      performDelete: () async {
        final snapshots = <Map<String, dynamic>>[];
        for (final item in completed) {
          final row =
              await ref.read(checklistProvider.notifier).deleteItemForUndo(item);
          if (row != null) snapshots.add(row);
        }
        return snapshots;
      },
      undo: (rows) {
        for (final row in rows) {
          ref.read(checklistProvider.notifier).restoreItem(row);
        }
      },
    );
  }
}
