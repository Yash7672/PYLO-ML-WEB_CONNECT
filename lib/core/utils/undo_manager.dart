import 'dart:async';

import 'package:flutter/material.dart';

import 'undo_snackbar.dart';

/// Runs the standard delete-with-undo interaction used by Lists, Tasks and
/// Habits so the three can never drift apart again:
///
/// 1. Calls [performDelete], which must persist the delete AND return a
///    per-item backup (a snapshot of the deleted rows — usually captured from
///    the DB just before the hard delete) so Undo can faithfully restore it.
///    Returning `null` means "nothing was deleted", and no SnackBar is shown.
/// 2. Shows a SnackBar whose Undo action is bound to exactly that backup
///    (see [showDeleteUndoSnackBar]: every call owns an independent backup
///    holder, so rapid deletes never overwrite each other).
/// 3. When Undo is tapped, invokes [undo] with the backup so the caller
///    re-inserts the rows with their ORIGINAL IDs and refreshes only its own
///    provider.
Future<void> deleteWithUndo<T>(
  ScaffoldMessengerState messenger, {
  required String message,
  required Future<T?> Function() performDelete,
  required FutureOr<void> Function(T backup) undo,
}) async {
  final backup = await performDelete();
  if (backup == null) return;
  showDeleteUndoSnackBar<T>(
    messenger,
    message: message,
    backup: backup,
    onUndo: (kept) => undo(kept),
  );
}