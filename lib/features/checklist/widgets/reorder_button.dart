import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// Single reorder control for a row: one Material-style vertical swap glyph
/// — a continuous stem with an arrowhead at each end — in place of the old
/// separate ↑ / ↓ pair.
///
/// Tapping **or holding** the button opens a small menu with "Move up" and
/// "Move down", so one control still reaches both directions. The direction
/// that would be a no-op for this row (the first row moving up, the last
/// row moving down) is greyed out inside the menu instead of being hidden,
/// so the control can never push a row out of bounds.
///
/// The button itself is PYLO's orange accent whenever either direction is
/// available and plain grey when neither is (a single-row list).
class ReorderButton extends StatelessWidget {
  const ReorderButton({
    super.key,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  /// False only when the row has nowhere to go at all.
  bool get _canMove => canMoveUp || canMoveDown;

  /// Anchors the popup to this button's own box so it opens beside the row
  /// rather than mid-screen.
  Future<void> _showMenu(BuildContext context) async {
    final RenderBox button = context.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final choice = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(
          value: 'up',
          enabled: canMoveUp,
          child: const Text('Move up'),
        ),
        PopupMenuItem<String>(
          value: 'down',
          enabled: canMoveDown,
          child: const Text('Move down'),
        ),
      ],
    );

    // A disabled item never reports a selection, so nothing fires for the
    // direction this row cannot take.
    if (choice == 'up') {
      onMoveUp();
    } else if (choice == 'down') {
      onMoveDown();
    }
  }

  @override
  Widget build(BuildContext context) {
    // PYLO's orange accent, referenced directly rather than through
    // `colorScheme.primary`: the light/dark/amoled themes seed their scheme
    // from `Colors.deepPurple`, so `primary` is purple there and only
    // happens to be orange in the glass theme. The glyph must be orange in
    // every theme.
    const enabled = GlassColors.accent;
    const disabled = Colors.grey;

    return IconButton(
      tooltip: 'Reorder',
      onPressed: _canMove ? () => _showMenu(context) : null,
      // Holding gives the same menu, so either gesture reaches both
      // directions. The button's own long-press wins the gesture arena over
      // the row's drag listener, so a hold here opens the menu instead of
      // dragging the row.
      onLongPress: _canMove ? () => _showMenu(context) : null,
      icon: const Icon(Icons.height, size: 20),
      // `shrinkWrap` opts out of the theme's 48px padded tap target, which
      // would blow the button up to 40px wide no matter what `constraints`
      // say. 32px keeps it well inside the 64px budget while staying an
      // easy tap.
      style:
          IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      // Explicit on both states: `color` alone leaves a disabled button on
      // the theme's default, which is not guaranteed to read as grey.
      color: enabled,
      disabledColor: disabled,
    );
  }
}
