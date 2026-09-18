import 'dart:async';

import 'package:flutter/material.dart';

/// Shows a "deleted" SnackBar whose Undo action is bound to its own scoped
/// copy of [backup]. Every call owns an independent holder, so rapid deletes
/// never overwrite each other's backup and each Undo restores exactly the item
/// it was shown for.
///
/// The backup is cleared in both directions:
///   - it is discarded right before Undo restores it, so the action cannot
///     fire twice; and
///   - `snack.closed` discards it whenever the SnackBar disappears for any
///     reason other than the Undo action (timeout, swipe, another SnackBar),
///     so a timed-out window cannot restore a stale item.
///
/// The SnackBar window defaults to 4 seconds to match the backup lifetime.
void showDeleteUndoSnackBar<T>(
  ScaffoldMessengerState messenger, {
  required String message,
  required T backup,
  String undoLabel = 'Undo',
  Duration duration = const Duration(seconds: 4),
  FutureOr<void> Function(T kept)? onUndo,
}) {
  T? holder = backup;
  messenger.clearSnackBars();
  final snack = messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      action: SnackBarAction(
        label: undoLabel,
        onPressed: () {
          final kept = holder;
          holder = null;
          if (kept != null) onUndo?.call(kept);
        },
      ),
    ),
  );
  snack.closed.then((reason) {
    if (reason != SnackBarClosedReason.action) holder = null;
  });
}