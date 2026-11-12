import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_app/core/utils/undo_snackbar.dart';

/// The delete-undo notification: a 3 - 2 - 1 circular countdown beside Undo
/// that dismisses itself after exactly 3 seconds and then leaves the deleted
/// item deleted for good.
void main() {
  /// A bare host with a ScaffoldMessenger (what every screen in the app has).
  Future<ScaffoldMessengerState> host(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    return tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
  }

  /// Unmounts everything so no timer from a still-visible notification can
  /// outlive the test.
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('counts 3, 2, 1 and dismisses itself after exactly 3 seconds',
      (tester) async {
    final messenger = await host(tester);
    final restored = <String>[];

    showDeleteUndoSnackBar<String>(
      messenger,
      message: 'Checklist deleted',
      backup: 'list-1',
      onUndo: restored.add,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // entrance

    expect(find.text('Checklist deleted'), findsOneWidget);
    expect(find.byType(UndoCountdownBadge), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'starts at 3');

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget, reason: 'ticks to 2 after 1s');

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget, reason: 'ticks to 1 after 2s');

    // Still on screen a moment before the full window elapses.
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(SnackBar), findsOneWidget);

    // ...and gone the instant it reaches zero, sliding out of view.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing,
        reason: 'notification dismisses itself at 3s');
    expect(restored, isEmpty,
        reason: 'an expired window never restores the item');

    await teardown(tester);
  });

  testWidgets('the countdown circle sits immediately beside Undo',
      (tester) async {
    final messenger = await host(tester);

    showDeleteUndoSnackBar<String>(
      messenger,
      message: 'Task deleted',
      backup: 'task-1',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final badge = tester.getRect(find.byType(UndoCountdownBadge));
    final undo = tester.getRect(find.text('Undo'));

    expect(badge.right, lessThanOrEqualTo(undo.left + 1),
        reason: 'circle is directly to the left of Undo');
    expect(badge.center.dy, closeTo(undo.center.dy, 12),
        reason: 'circle is vertically aligned with Undo');
    expect(badge.width, greaterThanOrEqualTo(20),
        reason: 'circle is big enough to read the number');

    await teardown(tester);
  });

  testWidgets('tapping Undo restores immediately and stops the countdown',
      (tester) async {
    final messenger = await host(tester);
    final restored = <String>[];

    showDeleteUndoSnackBar<String>(
      messenger,
      message: 'Habit deleted',
      backup: 'habit-1',
      onUndo: restored.add,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(restored, ['habit-1'], reason: 'restore happens on the tap');
    expect(find.byType(SnackBar), findsNothing);

    // Long past the original window: the cancelled countdown must not fire.
    await tester.pump(const Duration(seconds: 5));
    expect(restored, ['habit-1'], reason: 'Undo cannot fire twice');

    await teardown(tester);
  });

  testWidgets('rapid second delete is not killed by the first countdown',
      (tester) async {
    final messenger = await host(tester);
    final restored = <String>[];

    showDeleteUndoSnackBar<String>(
      messenger,
      message: 'First deleted',
      backup: 'A',
      onUndo: restored.add,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 2)); // first window almost over

    showDeleteUndoSnackBar<String>(
      messenger,
      message: 'Second deleted',
      backup: 'B',
      onUndo: restored.add,
    );
    await tester.pump();

    // Cross the first notification's expiry point.
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'a stale countdown must not throw or hide the new one');
    expect(find.text('Second deleted'), findsOneWidget);
    expect(find.text('First deleted'), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(restored, ['B'],
        reason: 'Undo restores exactly the item its own notification showed');
    expect(tester.takeException(), isNull);

    await teardown(tester);
  });
}
