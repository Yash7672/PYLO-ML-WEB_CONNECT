import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/undo_manager.dart';
import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../models/checklist_model.dart';
import '../../../providers/checklist_provider.dart';
import '../../../theme/app_theme.dart';
import 'move_arrows.dart';

class ChecklistItemTile extends ConsumerWidget {
  final ChecklistItem item;

  /// Position of this row inside its parent list plus the list length, so
  /// the ↑ / ↓ pair can grey itself out on the first / last row.
  final int index;
  final int itemCount;

  const ChecklistItemTile({
    super.key,
    required this.item,
    required this.index,
    required this.itemCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Dismissible(
      key: Key('item_${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) {
        final messenger = ScaffoldMessenger.of(context);
        // Capture the notifier NOW — swipe-delete unmounts this tile before
        // Undo is tapped, and reading `ref` from the unmounted consumer throws
        // `StateError: Cannot use "ref" after the widget was disposed` from
        // inside the SnackBar's onTap.
        final checklistNotifier = ref.read(checklistProvider.notifier);
        deleteWithUndo<Map<String, dynamic>>(
          messenger,
          message: 'Item deleted',
          performDelete: () => checklistNotifier.deleteItemForUndo(item),
          undo: (kept) => checklistNotifier.restoreItem(kept),
        );
      },
      child: CheckboxListTile(
        value: item.completed,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          item.text,
          style: theme.textTheme.bodyLarge?.copyWith(
            decoration:
                item.completed ? TextDecoration.lineThrough : null,
            color: item.completed
                ? (isGlassTheme(context)
                    ? GlassColors.textMuted
                    : Colors.grey)
                : null,
          ),
        ),
        onChanged: (_) =>
            ref.read(checklistProvider.notifier).toggleItem(item),
        // Keep the existing Edit button and put the compact ↑ / ↓ pair
        // right beside it, exactly like on the Lists page.
        secondary: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _editItem(context, ref),
            ),
            MoveArrows(
              // First row has nothing above it to move into; last row
              // has nothing below it.
              canMoveUp: index > 0,
              canMoveDown: index < itemCount - 1,
              onMoveUp: () => ref
                  .read(checklistProvider.notifier)
                  .reorderItems(item.checklistId, index, index - 1),
              onMoveDown: () => ref
                  .read(checklistProvider.notifier)
                  .reorderItems(item.checklistId, index, index + 1),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editItem(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: item.text);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => DisposeOnExit(
        controllers: [controller],
        child: AlertDialog(
          title: const Text('Edit Item'),
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
          .updateItemText(item, result);
    }
  }
}
