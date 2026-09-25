import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_app/core/widgets/glass_components.dart';
import 'package:task_app/theme/app_theme.dart';

void main() {
  test('non-Glass themes define opaque bottom sheet backgrounds', () {
    for (final theme in <ThemeData>[
      AppTheme.lightTheme,
      AppTheme.darkTheme,
      AppTheme.amoledTheme,
    ]) {
      final color = theme.bottomSheetTheme.backgroundColor;
      expect(color, isNotNull);
      expect(color!.a, 1.0);
    }

    expect(
      AppTheme.amoledTheme.bottomSheetTheme.backgroundColor,
      Colors.black,
    );
  });

  testWidgets('uses the active non-Glass bottom sheet background',
      (tester) async {
    const background = Color(0xFF123456);
    final theme = AppTheme.lightTheme.copyWith(
      bottomSheetTheme: AppTheme.lightTheme.bottomSheetTheme.copyWith(
        backgroundColor: background,
      ),
    );

    await tester.pumpWidget(_SheetHost(theme: theme));
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();

    final bottomSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(bottomSheet.backgroundColor, background);
    expect(find.byType(GlassSurface), findsNothing);
  });

  testWidgets('keeps the transparent route and GlassSurface in Glass',
      (tester) async {
    await tester.pumpWidget(_SheetHost(theme: AppTheme.glassTheme));
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();

    final bottomSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(bottomSheet.backgroundColor, Colors.transparent);
    expect(find.byType(GlassSurface), findsOneWidget);
  });
}

class _SheetHost extends StatelessWidget {
  final ThemeData theme;

  const _SheetHost({required this.theme});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              key: const ValueKey('open-sheet'),
              onPressed: () {
                showGlassBottomSheet<void>(
                  context,
                  child: const SizedBox(
                    height: 120,
                    child: Text('Sheet content'),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
  }
}
