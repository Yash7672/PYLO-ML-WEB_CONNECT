import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_app/database/database_helper.dart';
import 'package:task_app/features/checklist/screens/checklist_screen.dart';
import 'package:task_app/features/checklist/widgets/reorder_button.dart';
import 'package:task_app/models/checklist_model.dart';
import 'package:task_app/providers/checklist_provider.dart';
import 'package:task_app/providers/database_provider.dart';

/// Drag-and-drop reordering for the Lists page.
///
/// Parent lists and their sublists are covered by separate tests, because
/// they are two independent orderings: a parent drag must move the whole
/// group, a sublist drag must stay inside its own parent.
void main() {
  final db = DatabaseHelper.instance;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final dbsPath = await databaseFactory.getDatabasesPath();
    await Directory(dbsPath).create(recursive: true);
    DatabaseHelper.testDbPathOverride =
        p.join(dbsPath, 'taskflow_checklist_reorder_test.db');
  });

  setUp(() async {
    final path = await db.databasePath;
    await databaseFactory.deleteDatabase(path);
    await db.initDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// Creates a container, loads the provider and returns its notifier.
  Future<ChecklistNotifier> loadedNotifier(ProviderContainer c) async {
    final notifier = c.read(checklistProvider.notifier);
    await notifier.loadChecklists();
    return notifier;
  }

  Future<void> seedList(
    String id,
    String title, {
    required int position,
    List<(String, String)> items = const [],
  }) async {
    await db.createChecklist(Checklist(id: id, title: title, position: position));
    var itemPosition = 0;
    for (final (itemId, text) in items) {
      await db.createChecklistItem(ChecklistItem(
        id: itemId,
        checklistId: id,
        text: text,
        position: itemPosition++,
      ));
    }
  }

  /// Shopping / Bike / Study parents with their own sublists, seeded with
  /// explicit positions so the pre-drag order is deterministic.
  Future<void> seedDemo() async {
    await seedList('l1', 'Shopping',
        position: 0, items: [('a1', 'Book'), ('a2', 'Bag')]);
    await seedList('l2', 'Bike',
        position: 1,
        items: [('b1', 'Cycle'), ('b2', 'Repair'), ('b3', 'Service')]);
    await seedList('l3', 'Study', position: 2);
  }

  List<String> titles(ProviderContainer c) => c
      .read(checklistProvider)
      .checklists
      .map((list) => list.title)
      .toList();

  List<String> itemTexts(ProviderContainer c, String checklistId) =>
      (c.read(checklistProvider).items[checklistId] ?? const <ChecklistItem>[])
          .map((item) => item.text)
          .toList();

  /// Closes and reopens SQLite, then reloads the provider: everything a
  /// restart of the app would do.
  Future<void> restart(ProviderContainer c, ChecklistNotifier notifier) async {
    await db.close();
    await db.initDatabase();
    await notifier.loadChecklists();
  }

  // ── Model ────────────────────────────────────────────────────────────────

  test('checklist position round-trips through the database map', () {
    final checklist = Checklist(title: 'Shopping', position: 7);
    final restored = Checklist.fromMap(checklist.toMap());

    expect(restored.position, 7);
    // A row written before the column existed still parses.
    expect(Checklist.fromMap({'id': 'x', 'title': 'Old'}).position, 0);
  });

  // ── Schema upgrade ───────────────────────────────────────────────────────

  test('v12 -> v13 upgrade keeps the visible order and backfills positions',
      () async {
    // Simulate an existing install: the pre-reorder schema, no `position`
    // column, lists ordered by updatedAt DESC (what the app showed before).
    final path = await db.databasePath;
    await db.close();
    await databaseFactory.deleteDatabase(path);
    final legacy = await databaseFactory.openDatabase(path);
    await legacy.execute('''
        CREATE TABLE checklists (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          createdAt INTEGER,
          updatedAt INTEGER
        )
      ''');
    await legacy.execute('''
        CREATE TABLE checklist_items (
          id TEXT PRIMARY KEY,
          checklistId TEXT NOT NULL,
          text TEXT NOT NULL,
          completed INTEGER DEFAULT 0,
          position INTEGER DEFAULT 0
        )
      ''');
    // Pretend the file was last opened by schema v12 (pre-reorder app).
    await legacy.execute('PRAGMA user_version = 12');
    await legacy.insert('checklists',
        {'id': 'x1', 'title': 'Bike', 'createdAt': 1, 'updatedAt': 300});
    await legacy.insert('checklists',
        {'id': 'x2', 'title': 'Shopping', 'createdAt': 2, 'updatedAt': 200});
    await legacy.insert('checklists',
        {'id': 'x3', 'title': 'Study', 'createdAt': 3, 'updatedAt': 100});
    await legacy.close();

    // Reopen with the app: the upgrade must not move a single list.
    await db.initDatabase();
    final upgraded = await db.getAllChecklists();
    expect(upgraded.map((list) => list.title).toList(),
        ['Bike', 'Shopping', 'Study']);
    expect(upgraded.map((list) => list.position).toList(), [0, 1, 2]);

    // And reordering an upgraded database persists like any other.
    final container = createContainer();
    final notifier = await loadedNotifier(container);
    await notifier.reorderChecklists(0, 2);
    expect(titles(container), ['Shopping', 'Study', 'Bike']);

    await restart(container, notifier);
    expect(titles(container), ['Shopping', 'Study', 'Bike']);
  });

  // ── Parent list reordering ───────────────────────────────────────────────

  test('parent lists can be dragged into a new order and it survives a restart',
      () async {
    await seedDemo();
    final container = createContainer();
    final notifier = await loadedNotifier(container);

    expect(titles(container), ['Shopping', 'Bike', 'Study']);

    // Long-press drag "Shopping" (index 0) down to the bottom (index 2).
    await notifier.reorderChecklists(0, 2);
    expect(titles(container), ['Bike', 'Study', 'Shopping']);

    await restart(container, notifier);

    expect(titles(container), ['Bike', 'Study', 'Shopping']);
    // The whole group travelled with its parent.
    expect(itemTexts(container, 'l1'), ['Book', 'Bag']);
    expect(itemTexts(container, 'l2'), ['Cycle', 'Repair', 'Service']);
  });

  test('a parent drag moves only the parents, never the sublists', () async {
    await seedDemo();
    final container = createContainer();
    final notifier = await loadedNotifier(container);

    // Swap the two first parents.
    await notifier.reorderChecklists(0, 1);

    expect(titles(container), ['Bike', 'Shopping', 'Study']);
    expect(itemTexts(container, 'l1'), ['Book', 'Bag']);
    expect(itemTexts(container, 'l2'), ['Cycle', 'Repair', 'Service']);

    final rows = await db.getAllChecklists();
    expect(rows.map((list) => list.id).toList(), ['l2', 'l1', 'l3']);
    expect(rows.map((list) => list.position).toList(), [0, 1, 2]);
  });

  // ── Sublist (item) reordering ────────────────────────────────────────────

  test('sublists can be dragged inside their own list and it survives a restart',
      () async {
    await seedDemo();
    final container = createContainer();
    final notifier = await loadedNotifier(container);

    expect(itemTexts(container, 'l1'), ['Book', 'Bag']);

    // Long-press drag "Book" (index 0) below "Bag".
    await notifier.reorderItems('l1', 0, 1);
    expect(itemTexts(container, 'l1'), ['Bag', 'Book']);

    await restart(container, notifier);

    expect(itemTexts(container, 'l1'), ['Bag', 'Book']);
    // The other parent's list is untouched.
    expect(itemTexts(container, 'l2'), ['Cycle', 'Repair', 'Service']);
    expect(titles(container), ['Shopping', 'Bike', 'Study']);
  });

  test('a sublist drag never crosses into another parent list', () async {
    await seedDemo();
    final container = createContainer();
    final notifier = await loadedNotifier(container);

    // Drag "Cycle" (index 0) to the bottom of the Bike list.
    await notifier.reorderItems('l2', 0, 2);
    expect(itemTexts(container, 'l2'), ['Repair', 'Service', 'Cycle']);
    expect(itemTexts(container, 'l1'), ['Book', 'Bag']);

    await restart(container, notifier);
    expect(itemTexts(container, 'l2'), ['Repair', 'Service', 'Cycle']);
    expect(itemTexts(container, 'l1'), ['Book', 'Bag']);
  });

  test('the SQL position write is scoped to a single parent list', () async {
    await seedDemo();

    // Even a caller handing over another list's ids must not move those rows.
    await db.updateChecklistItemPositions('l1', ['b1', 'b2', 'b3', 'a1']);

    final bike = await db.getChecklistItems('l2');
    expect(bike.map((item) => item.id).toList(), ['b1', 'b2', 'b3']);
    expect(bike.map((item) => item.position).toList(), [0, 1, 2]);

    final shopping = await db.getChecklistItems('l1');
    expect(shopping.map((item) => item.id).toList(), ['a2', 'a1']);
  });

  // ── Existing operations still behave after a reorder ─────────────────────

  test('create, rename, complete, add, delete+undo work after a reorder',
      () async {
    await seedDemo();
    final container = createContainer();
    final notifier = await loadedNotifier(container);

    await notifier.reorderChecklists(0, 1);
    expect(titles(container), ['Bike', 'Shopping', 'Study']);

    // Rename keeps the list in place.
    final shopping =
        container.read(checklistProvider).checklists.firstWhere((l) => l.id == 'l1');
    await notifier.renameChecklist(shopping, 'Groceries');
    expect(titles(container), ['Bike', 'Groceries', 'Study']);

    // A brand-new list still lands on top.
    await notifier.createChecklist('Packing');
    expect(titles(container).first, 'Packing');

    // Completing an item keeps its position.
    final book = container.read(checklistProvider).items['l1']!.first;
    await notifier.toggleItem(book);
    expect(container.read(checklistProvider).items['l1']!.first.completed, isTrue);

    // New items are appended at the end of their own list.
    await notifier.addItem('l1', 'Milk');
    expect(itemTexts(container, 'l1'), ['Book', 'Bag', 'Milk']);

    // Delete + undo restores the list with its original order.
    final packing =
        container.read(checklistProvider).checklists.firstWhere((l) => l.title == 'Packing');
    final snapshot = await notifier.deleteChecklistForUndo(packing);
    expect(titles(container), ['Bike', 'Groceries', 'Study']);
    expect(snapshot, isNotNull);

    await notifier.restoreChecklist(snapshot!);
    expect(titles(container), ['Packing', 'Bike', 'Groceries', 'Study']);

    await restart(container, notifier);
    expect(titles(container), ['Packing', 'Bike', 'Groceries', 'Study']);
    expect(itemTexts(container, 'l1'), ['Book', 'Bag', 'Milk']);
  });

  // ── On-screen drag (long press) ──────────────────────────────────────────

  testWidgets('long-press drag reorders the parent lists on screen',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Shopping', 'Bike', 'Study']),
        ['Shopping', 'Bike', 'Study']);

    await longPressDrag(tester, find.text('Shopping'), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Shopping', 'Bike', 'Study']),
        ['Bike', 'Study', 'Shopping']);

    // The new order is in SQLite, not just on screen.
    await flushWrites(tester);
    final rows = await db.getAllChecklists();
    expect(rows.map((list) => list.title).toList(),
        ['Bike', 'Study', 'Shopping']);
  });

  testWidgets('long-press drag reorders sublists inside their own list',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    // Open the Bike list.
    await tester.tap(find.text('Bike'));
    await tester.pumpAndSettle();
    expect(find.text('Cycle'), findsOneWidget);

    await longPressDrag(tester, find.text('Cycle'), const Offset(0, 180));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Cycle', 'Repair', 'Service']),
        ['Repair', 'Service', 'Cycle'], reason: 'Bike list reordered');

    await flushWrites(tester);
    final bike = await db.getChecklistItems('l2');
    expect(bike.map((item) => item.text).toList(), ['Repair', 'Service', 'Cycle']);
    final shopping = await db.getChecklistItems('l1');
    expect(shopping.map((item) => item.text).toList(), ['Book', 'Bag']);
  });

  // ── Single swap button (reorder without dragging) ─────────────────────────

  testWidgets('the reorder control is a single compact swap button',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    // One control per row, drawn with the single-stem swap glyph rather
    // than the two separate arrows it replaced.
    final buttons =
        tester.widgetList<ReorderButton>(find.byType(ReorderButton));
    expect(buttons, hasLength(3), reason: 'one control per list row');
    expect(find.byIcon(Icons.height), findsNWidgets(3),
        reason: 'each row shows exactly one swap glyph');
    expect(find.byIcon(Icons.arrow_upward), findsNothing,
        reason: 'the separate Up arrow is gone');
    expect(find.byIcon(Icons.arrow_downward), findsNothing,
        reason: 'the separate Down arrow is gone');

    final size = tester.getSize(find.byType(ReorderButton).first);
    expect(size.width, lessThanOrEqualTo(64),
        reason: 'the control must stay compact beside the menu');
    expect(size.height, lessThanOrEqualTo(32));
  });

  testWidgets('Move up is disabled on the first list, Move down on the last',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    // The button stays live on every row — the unavailable direction is
    // greyed out inside its menu instead.
    await openMoveMenu(tester, 'Shopping');
    expect(menuEnabled(tester, 'Move up'), isFalse,
        reason: 'the first list has nothing above it to move into');
    expect(menuEnabled(tester, 'Move down'), isTrue,
        reason: 'the first list can move down');
    await closeMoveMenu(tester);

    await openMoveMenu(tester, 'Study');
    expect(menuEnabled(tester, 'Move up'), isTrue,
        reason: 'the last list can move up');
    expect(menuEnabled(tester, 'Move down'), isFalse,
        reason: 'the last list has nothing below it to move into');
    await closeMoveMenu(tester);

    // The middle list can move both ways.
    await openMoveMenu(tester, 'Bike');
    expect(menuEnabled(tester, 'Move up'), isTrue);
    expect(menuEnabled(tester, 'Move down'), isTrue);
    await closeMoveMenu(tester);
  });

  testWidgets('Down then Up move a list one position and persist',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Shopping', 'Bike', 'Study']),
        ['Shopping', 'Bike', 'Study']);

    await openMoveMenu(tester, 'Shopping');
    await tester.tap(find.text('Move down'));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Shopping', 'Bike', 'Study']),
        ['Bike', 'Shopping', 'Study'],
        reason: 'Down moves the list exactly one position');

    await flushWrites(tester);
    expect((await db.getAllChecklists()).map((l) => l.title).toList(),
        ['Bike', 'Shopping', 'Study'],
        reason: 'the new order is written to SQLite');

    await openMoveMenu(tester, 'Shopping');
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Shopping', 'Bike', 'Study']),
        ['Shopping', 'Bike', 'Study'],
        reason: 'Up moves the list back exactly one position');

    await flushWrites(tester);
    expect((await db.getAllChecklists()).map((l) => l.title).toList(),
        ['Shopping', 'Bike', 'Study'],
        reason: 'and that order is persisted too');
  });

  // ── Swap button inside a list (item rows) ─────────────────────────────────

  testWidgets('item Move up is disabled on the first row, Move down on the last',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    // Open the Bike list: Cycle / Repair / Service.
    await tester.tap(find.text('Bike'));
    await tester.pumpAndSettle();

    await openMoveMenu(tester, 'Cycle');
    expect(menuEnabled(tester, 'Move up'), isFalse,
        reason: 'the first item has nothing above it to move into');
    expect(menuEnabled(tester, 'Move down'), isTrue,
        reason: 'the first item can move down');
    await closeMoveMenu(tester);

    await openMoveMenu(tester, 'Service');
    expect(menuEnabled(tester, 'Move up'), isTrue,
        reason: 'the last item can move up');
    expect(menuEnabled(tester, 'Move down'), isFalse,
        reason: 'the last item has nothing below it to move into');
    await closeMoveMenu(tester);

    // The middle row can move both ways.
    await openMoveMenu(tester, 'Repair');
    expect(menuEnabled(tester, 'Move up'), isTrue);
    expect(menuEnabled(tester, 'Move down'), isTrue);
    await closeMoveMenu(tester);
  });

  testWidgets('item Down then Up move an item one position and persist',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bike'));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Cycle', 'Repair', 'Service']),
        ['Cycle', 'Repair', 'Service']);

    await openMoveMenu(tester, 'Cycle');
    await tester.tap(find.text('Move down'));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Cycle', 'Repair', 'Service']),
        ['Repair', 'Cycle', 'Service'],
        reason: 'Down moves the item exactly one position');

    await flushWrites(tester);
    expect((await db.getChecklistItems('l2')).map((i) => i.text).toList(),
        ['Repair', 'Cycle', 'Service'],
        reason: 'the new item order is written to SQLite');

    await openMoveMenu(tester, 'Cycle');
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();

    expect(orderOf(tester, const ['Cycle', 'Repair', 'Service']),
        ['Cycle', 'Repair', 'Service'],
        reason: 'Up moves the item back exactly one position');

    await flushWrites(tester);
    expect((await db.getChecklistItems('l2')).map((i) => i.text).toList(),
        ['Cycle', 'Repair', 'Service'],
        reason: 'and that item order is persisted too');
  });

  testWidgets('the item menu never moves an item into another list',
      (tester) async {
    await seedDemo();

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bike'));
    await tester.pumpAndSettle();

    // The last row's Move down entry is disabled, so choosing it is a no-op:
    // no state change, no write. A disabled entry also leaves the menu open,
    // so dismiss it explicitly before asserting.
    await openMoveMenu(tester, 'Service');
    expect(menuEnabled(tester, 'Move down'), isFalse,
        reason: 'the last item has nothing below it to move into');
    await tester.tap(find.text('Move down'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await closeMoveMenu(tester);
    await flushWrites(tester);

    expect(orderOf(tester, const ['Cycle', 'Repair', 'Service']),
        ['Cycle', 'Repair', 'Service']);
    expect((await db.getChecklistItems('l2')).map((i) => i.text).toList(),
        ['Cycle', 'Repair', 'Service']);
    // The other parent list is untouched too.
    expect((await db.getChecklistItems('l1')).map((i) => i.text).toList(),
        ['Book', 'Bag']);
  });

  testWidgets('item row with Edit + swap button fits a 320px phone without overflow',
      (tester) async {
    await seedDemo();

    // A very narrow old-school phone: the row must not overflow even with
    // two trailing controls (Edit and the swap button).
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: ChecklistScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bike'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'the Edit + swap group must not overflow the row');
    // The item text is still visible, not squeezed out by the controls.
    expect(find.text('Cycle'), findsOneWidget);
    expect(find.text('Service'), findsOneWidget);
  });
}

// ── Widget-test helpers ────────────────────────────────────────────────────

/// The on-screen order (top to bottom) of the given row titles.
List<String> orderOf(WidgetTester tester, List<String> labels) {
  final sorted = [...labels];
  sorted.sort((a, b) => tester
      .getTopLeft(find.text(a))
      .dy
      .compareTo(tester.getTopLeft(find.text(b)).dy));
  return sorted;
}

/// The reorder button that belongs to the row showing [title].
Finder moveButton(String title) => find.descendant(
      of: find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
      matching: find.byType(ReorderButton),
    );

/// Opens the Move up / Move down menu for the row showing [title].
Future<void> openMoveMenu(WidgetTester tester, String title) async {
  await tester.tap(moveButton(title));
  await tester.pumpAndSettle();
}

/// Dismisses the open menu without choosing anything. The menu is anchored
/// to its button on the right edge of the row, so a tap in the left gutter
/// lands on the route's full-screen barrier and closes it.
Future<void> closeMoveMenu(WidgetTester tester) async {
  final dy = tester.getCenter(find.text('Move up')).dy;
  await tester.tapAt(Offset(4, dy));
  await tester.pumpAndSettle();
}

/// The Move up / Move down entry inside the open menu.
Finder menuItem(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
    );

/// Whether the menu entry [label] can be chosen for the current row.
bool menuEnabled(WidgetTester tester, String label) =>
    tester.widget<PopupMenuItem<dynamic>>(menuItem(label)).enabled;

/// Long-presses [finder], drags by [offset] and drops.
Future<void> longPressDrag(
  WidgetTester tester,
  Finder finder,
  Offset offset,
) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  // Long-press delay (kLongPressTimeout) must elapse before the drag starts.
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.moveBy(offset);
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Lets queued SQLite writes land and advances past the 400ms home-widget
/// debounce so no timer is left pending when the test ends.
Future<void> flushWrites(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)));
}
