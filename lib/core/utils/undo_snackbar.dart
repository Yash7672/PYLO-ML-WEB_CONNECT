import 'dart:async';

import 'package:flutter/material.dart';

/// Generation of the newest delete-undo SnackBar.
///
/// Every [showDeleteUndoSnackBar] call bumps it. A SnackBar that is already on
/// its way out (replaced by a newer delete) compares its own generation before
/// touching the messenger, so a stale countdown can never dismiss the SnackBar
/// that replaced it — rapid deletes can't fight over the messenger.
int _undoGeneration = 0;

/// Shows a "deleted" SnackBar with a circular 3 - 2 - 1 countdown beside the
/// Undo action, whose action is bound to its own scoped copy of [backup].
///
/// Every call owns an independent holder, so rapid deletes never overwrite
/// each other's backup and each Undo restores exactly the item it was shown
/// for.
///
/// Lifetime (exactly [duration], 3 seconds by default):
///   - the badge ticks 3 -> 2 -> 1 once per second;
///   - when it reaches zero the SnackBar dismisses itself with the standard
///     exit animation and the backup is discarded, so the deletion becomes
///     permanent;
///   - tapping Undo restores the item immediately instead: the action clears
///     the holder first, so it can never fire twice.
///
/// The backup is also discarded whenever the SnackBar disappears for any
/// reason other than the Undo action (swipe, another SnackBar), so a
/// timed-out window can never restore a stale item.
void showDeleteUndoSnackBar<T>(
  ScaffoldMessengerState messenger, {
  required String message,
  required T backup,
  String undoLabel = 'Undo',
  Duration duration = const Duration(seconds: 3),
  FutureOr<void> Function(T kept)? onUndo,
}) {
  T? holder = backup;
  final generation = ++_undoGeneration;
  var settled = false;

  messenger.clearSnackBars();

  final snack = messenger.showSnackBar(
    SnackBar(
      duration: duration,
      content: Row(
        children: [
          Expanded(child: Text(message)),
          const SizedBox(width: 12),
          UndoCountdownBadge(
            seconds: duration.inSeconds,
            onExpired: () {
              // Only the newest, still-live SnackBar may dismiss itself:
              // if Undo already ran, or a newer delete replaced this one,
              // this countdown must leave the messenger alone.
              if (settled || generation != _undoGeneration) return;
              settled = true;
              messenger.hideCurrentSnackBar();
            },
          ),
        ],
      ),
      action: SnackBarAction(
        label: undoLabel,
        onPressed: () {
          settled = true;
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

/// Circular countdown badge shown beside the Undo action of a delete SnackBar.
///
/// It ticks [seconds] -> 1 once per second, drawing a ring that empties as the
/// numbers fall, and calls [onExpired] the moment it reaches zero. The timer
/// is cancelled in [dispose], so dismissing the SnackBar (or replacing it with
/// a newer delete) always stops its clock — no timer is left running behind a
/// SnackBar that is no longer on screen.
class UndoCountdownBadge extends StatefulWidget {
  const UndoCountdownBadge({
    super.key,
    required this.seconds,
    required this.onExpired,
  });

  /// Starting value of the countdown (3 for a delete-undo window).
  final int seconds;

  /// Called once, when the countdown reaches zero.
  final VoidCallback onExpired;

  @override
  State<UndoCountdownBadge> createState() => _UndoCountdownBadgeState();
}

class _UndoCountdownBadgeState extends State<UndoCountdownBadge> {
  Timer? _timer;
  late int _remaining = widget.seconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remaining <= 1) {
        timer.cancel();
        _timer = null;
        if (mounted) setState(() => _remaining = 0);
        widget.onExpired();
        return;
      }
      if (mounted) setState(() => _remaining--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Inherit the SnackBar's own foreground colour so the ring and the number
    // stay readable on any theme (glass, light or dark).
    final color = DefaultTextStyle.of(context).style.color ?? Colors.white;
    final total = widget.seconds <= 0 ? 1 : widget.seconds;

    return SizedBox(
      width: 26,
      height: 26,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 1.0, end: _remaining / total),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => CircularProgressIndicator(
                value: value.clamp(0.0, 1.0),
                strokeWidth: 2.5,
                color: color,
                backgroundColor: color.withValues(alpha: 0.25),
              ),
            ),
          ),
          Text(
            '$_remaining',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
