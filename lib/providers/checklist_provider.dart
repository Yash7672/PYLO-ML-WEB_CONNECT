import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_helper.dart';
import '../models/checklist_model.dart';
import '../services/home_widget_service.dart';
import 'database_provider.dart';

class ChecklistsState {
  final List<Checklist> checklists;
  final Map<String, List<ChecklistItem>> items;

  const ChecklistsState({
    this.checklists = const [],
    this.items = const {},
  });
}

/// Snapshot of a checklist and its items captured just before a hard delete,
/// so an Undo action can re-insert them with the exact same row IDs.
class ChecklistDeleteSnapshot {
  final Map<String, dynamic> checklistRow;
  final List<Map<String, dynamic>> items;

  const ChecklistDeleteSnapshot({
    required this.checklistRow,
    required this.items,
  });
}

final checklistProvider =
    StateNotifierProvider<ChecklistNotifier, ChecklistsState>((ref) {
  final dbHelper = ref.watch(databaseProvider);
  return ChecklistNotifier(dbHelper);
});

class ChecklistNotifier extends StateNotifier<ChecklistsState> {
  final DatabaseHelper dbHelper;

  /// Serializes checklist mutations so overlapping taps (double-toggle,
  /// rapid add-then-delete) apply one after the other instead of writing
  /// stale snapshots twice.
  Future<void>? _mutationQueue;

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final result = (_mutationQueue ?? Future.value()).then((_) => action());
    _mutationQueue = result.then<void>((_) {}, onError: (Object e, StackTrace st) {});
    return result;
  }

  ChecklistNotifier(this.dbHelper) : super(const ChecklistsState()) {
    loadChecklists();
  }

  /// Coalesces rapid item toggles/taps into a single debounced widget push so
  /// the platform channel is not hammered once per tap (double-toggles would
  /// otherwise write the full widget data twice back-to-back).
  Timer? _widgetDebounce;
  void _updateChecklistWidget() {
    _widgetDebounce?.cancel();
    _widgetDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(HomeWidgetService.refreshChecklist(
        checklists: state.checklists,
        items: state.items,
      ));
    });
  }

  @override
  void dispose() {
    _widgetDebounce?.cancel();
    super.dispose();
  }

  Future<void> loadChecklists() async {
    try {
      final checklists = await dbHelper.getAllChecklists();
      final items = await dbHelper.getAllChecklistItems();
      state = ChecklistsState(checklists: checklists, items: items);
      _updateChecklistWidget();
    } catch (e) {
      debugPrint('Error loading checklists: $e');
    }
  }

  Future<Checklist?> createChecklist(String title) async {
    return _runExclusive(() async {
      try {
        final checklist =
            await dbHelper.createChecklist(Checklist(title: title));
        state = ChecklistsState(
          checklists: [checklist, ...state.checklists],
          items: {...state.items, checklist.id: []},
        );
        return checklist;
      } catch (e) {
        debugPrint('Error creating checklist: $e');
        return null;
      }
    });
  }

  Future<void> renameChecklist(Checklist checklist, String title) async {
    await _runExclusive(() async {
      try {
        final updated = checklist.copyWith(title: title);
        await dbHelper.updateChecklist(updated);
        final list = [...state.checklists];
        final index = list.indexWhere((c) => c.id == checklist.id);
        if (index != -1) {
          list[index] = updated;
          state = ChecklistsState(checklists: list, items: state.items);
        }
      } catch (e) {
        debugPrint('Error renaming checklist: $e');
      }
    });
  }

  /// Deletes a checklist but first snapshots the checklist and its items from
  /// the database so an Undo can restore them with original row IDs.
  Future<ChecklistDeleteSnapshot?> deleteChecklistForUndo(
      Checklist checklist) {
    return _runExclusive(() async {
      try {
        final rows = await dbHelper.queryRows(
          'checklists',
          where: 'id = ?',
          whereArgs: [checklist.id],
        );
        if (rows.isEmpty) return null;
        final items = await dbHelper.queryRows(
          'checklist_items',
          where: 'checklistId = ?',
          whereArgs: [checklist.id],
          orderBy: 'position ASC',
        );
        await dbHelper.deleteChecklist(checklist.id);
        final stateItems = {...state.items}..remove(checklist.id);
        state = ChecklistsState(
          checklists:
              state.checklists.where((c) => c.id != checklist.id).toList(),
          items: stateItems,
        );
        _updateChecklistWidget();
        return ChecklistDeleteSnapshot(checklistRow: rows.first, items: items);
      } catch (e) {
        debugPrint('Error deleting checklist: $e');
        return null;
      }
    });
  }

  /// Re-inserts a deleted checklist and its items (original IDs preserved).
  Future<void> restoreChecklist(ChecklistDeleteSnapshot snapshot) async {
    await _runExclusive(() async {
      try {
        await dbHelper.restoreRows('checklists', [snapshot.checklistRow]);
        await dbHelper.restoreRows('checklist_items', snapshot.items);
        final checklists = await dbHelper.getAllChecklists();
        final items = await dbHelper.getAllChecklistItems();
        state = ChecklistsState(checklists: checklists, items: items);
        _updateChecklistWidget();
      } catch (e) {
        debugPrint('Error restoring checklist: $e');
      }
    });
  }

  /// Deletes a checklist item but first snapshots its row so an Undo can
  /// restore it. Optimistically removes the row on the current frame (so a
  /// swiped Dismissible leaves the tree immediately), then snapshots and
  /// hard-deletes inside the mutation queue.
  Future<Map<String, dynamic>?> deleteItemForUndo(ChecklistItem item) {
    // Optimistic update first so the swiped row leaves the tree on the same
    // frame (avoids 'dismissed Dismissible still part of the tree').
    final items = {...state.items};
    final list = [...(items[item.checklistId] ?? const <ChecklistItem>[])];
    list.removeWhere((i) => i.id == item.id);
    items[item.checklistId] = list;
    state = ChecklistsState(checklists: state.checklists, items: items);
    _updateChecklistWidget();
    return _runExclusive(() async {
      try {
        final rows = await dbHelper.queryRows(
          'checklist_items',
          where: 'id = ?',
          whereArgs: [item.id],
        );
        await dbHelper.deleteChecklistItem(item.id, item.checklistId);
        return rows.isEmpty ? null : rows.first;
      } catch (e) {
        debugPrint('Error deleting checklist item: $e');
        await loadChecklists();
        return null;
      }
    });
  }

  /// Re-inserts a checklist item from a snapshot row and reloads that
  /// checklist's items to restore canonical order.
  Future<void> restoreItem(Map<String, dynamic> row) async {
    await _runExclusive(() async {
      try {
        final item = ChecklistItem.fromMap(row);
        await dbHelper.restoreChecklistItem(item);
        final fresh = await dbHelper.getChecklistItems(item.checklistId);
        final items = {...state.items};
        items[item.checklistId] = fresh;
        state = ChecklistsState(checklists: state.checklists, items: items);
        _updateChecklistWidget();
      } catch (e) {
        debugPrint('Error restoring checklist item: $e');
      }
    });
  }

  Future<void> addItem(String checklistId, String text) async {
    if (text.trim().isEmpty) return;
    await _runExclusive(() async {
      try {
        // Position must be computed from the CURRENT list (never the stale
        // caller snapshot) and as max+1 so deleting a row can never make a
        // later insert reuse an existing position.
        final list = state.items[checklistId] ?? const <ChecklistItem>[];
        final nextPosition = list.isEmpty
            ? 0
            : (list.map((i) => i.position).reduce((a, b) => a > b ? a : b) + 1);
        final item = await dbHelper.createChecklistItem(
          ChecklistItem(
            checklistId: checklistId,
            text: text.trim(),
            position: nextPosition,
          ),
        );
        _upsertItem(item);
        _updateChecklistWidget();
      } catch (e) {
        debugPrint('Error adding checklist item: $e');
      }
    });
  }

  Future<void> toggleItem(ChecklistItem item) async {
    await _runExclusive(() async {
      try {
        // Re-read the row inside the queue so a quick double-tap flips the
        // checkbox twice (on then off) instead of writing 'on' twice.
        final list = state.items[item.checklistId] ?? const <ChecklistItem>[];
        final index = list.indexWhere((i) => i.id == item.id);
        final target = index != -1 ? list[index] : item;
        final updated = target.copyWith(completed: !target.completed);
        await dbHelper.updateChecklistItem(updated);
        _upsertItem(updated);
        _updateChecklistWidget();
      } catch (e) {
        debugPrint('Error toggling checklist item: $e');
      }
    });
  }

  Future<void> updateItemText(ChecklistItem item, String text) async {
    await _runExclusive(() async {
      try {
        final updated = item.copyWith(text: text.trim());
        await dbHelper.updateChecklistItem(updated);
        _upsertItem(updated);
        _updateChecklistWidget();
      } catch (e) {
        debugPrint('Error updating checklist item: $e');
      }
    });
  }

  void _upsertItem(ChecklistItem item) {
    final items = {...state.items};
    final list = [...(items[item.checklistId] ?? const <ChecklistItem>[])];
    final index = list.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      list[index] = item;
    } else {
      list.add(item);
    }
    items[item.checklistId] = list;
    state = ChecklistsState(checklists: state.checklists, items: items);
  }
}
