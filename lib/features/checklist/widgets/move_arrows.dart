import 'package:flutter/material.dart';

/// Compact Up / Down pair that moves a row exactly one position without
/// dragging. The two arrows sit side by side in one tight group — the way
/// the mobile-data glyph pairs its ↑ and ↓ — so both controls together
/// cost roughly what a single standard icon button used to take.
///
/// [canMoveUp] is false on the very first row and [canMoveDown] on the
/// last, so the pair can never be pressed into an invalid position; a
/// disabled arrow is greyed out and untappable.
class MoveArrows extends StatelessWidget {
  const MoveArrows({
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

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _arrow(
          tooltip: 'Move up',
          icon: Icons.arrow_upward,
          enabled: canMoveUp,
          color: primary,
          onPressed: onMoveUp,
        ),
        _arrow(
          tooltip: 'Move down',
          icon: Icons.arrow_downward,
          enabled: canMoveDown,
          color: primary,
          onPressed: onMoveDown,
        ),
      ],
    );
  }

  Widget _arrow({
    required String tooltip,
    required IconData icon,
    required bool enabled,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon, size: 18),
      // `shrinkWrap` opts out of the theme's 48px padded tap target, which
      // would blow every arrow up to 40px wide no matter what `constraints`
      // say. 32px keeps the pair at 64px total — 16px narrower than the two
      // 40px buttons it replaced — while staying an easy tap.
      style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      color: enabled ? color : null,
    );
  }
}
