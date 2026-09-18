import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/undo_manager.dart';
import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../models/checklist_model.dart';
import '../../../providers/checklist_provider.dart';
import '../../../theme/app_theme.dart';

class ChecklistItemTile extends ConsumerWidget {
  final ChecklistItem item;

  const ChecklistItemTile({super.key, required this.item});

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
        secondary: IconButton(
          icon: const Icon(Icons.edit_outlined, size: 20),
          onPressed: () => _editItem(context, ref),
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
