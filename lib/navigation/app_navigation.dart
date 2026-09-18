import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/widgets/glass_components.dart';
import '../theme/glass_depth.dart';
import '../features/calendar/screens/calendar_screen.dart';
import '../features/checklist/screens/checklist_screen.dart';
import '../features/dashboard/screens/dashboard_screen.dart';
import '../features/more/screens/more_screen.dart';
import '../features/streaks/screens/streaks_screen.dart';
import '../features/tasks/screens/task_list_screen.dart';
import '../providers/focus_provider.dart';

class AppNavigation extends ConsumerStatefulWidget {
  const AppNavigation({super.key});

  @override
  ConsumerState<AppNavigation> createState() => _AppNavigationState();
}

class _AppNavigationState extends ConsumerState<AppNavigation> {
  int _currentIndex = 0;
  bool _hasActiveFocus = false;

  /// IndexedStack keeps already-visited screens alive so switching tabs does
  /// not rebuild them from scratch — preserving scroll position, loaded data,
  /// and avoiding duplicate provider watches. Screens are built LAZILY: a
  /// tab's sometimes-heavy tree (e.g. the calendar's month grid) is only
  /// mounted the first time it is visited, so the dashboard is the only tab
  /// paid for at unlock.
  final Set<int> _visitedTabs = {0};

  static Widget _screenFor(int index) => switch (index) {
        0 => const DashboardScreen(),
        1 => const TaskListScreen(),
        2 => const CalendarScreen(),
        3 => const StreaksScreen(),
        4 => const ChecklistScreen(),
        5 => const MoreScreen(),
        _ => const SizedBox.shrink(),
      };

  void _onDestinationSelected(int index) {
    setState(() {
      _currentIndex = index;
      _visitedTabs.add(index);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Use ref.listen to only rebuild when active focus actually changes,
      // instead of watching the full FocusState (which rebuilds every second
      // during an active session).
      ref.listenManual<FocusState>(focusProvider, (prev, next) {
        final wasActive = prev?.active != null;
        final isActive = next.active != null;
        if (wasActive != isActive) {
          setState(() => _hasActiveFocus = isActive);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_hasActiveFocus) {
      return const SizedBox.shrink();
    }

    final isGlass = isGlassTheme(context);

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          for (var i = 0; i < 6; i++)
            _visitedTabs.contains(i)
                ? _screenFor(i)
                : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: isGlass
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: GlassSurface(
                borderRadius: 24,
                depth: GlassDepth.level3,
                // Explicit override slightly below the level3 default: the nav
                // bar is full-width and present on every tab, so its blur is
                // the single largest standing GPU cost in the Glass theme.
                blur: 14,
                child: NavigationBar(
                  selectedIndex: _currentIndex,
                  onDestinationSelected: _onDestinationSelected,
                  destinations: const [
                    NavigationDestination(
                        icon: Icon(Icons.dashboard_outlined),
                        selectedIcon: Icon(Icons.dashboard),
                        label: 'Home'),
                    NavigationDestination(
                        icon: Icon(Icons.list_alt_outlined),
                        selectedIcon: Icon(Icons.list_alt),
                        label: 'Tasks'),
                    NavigationDestination(
                        icon: Icon(Icons.calendar_month_outlined),
                        selectedIcon: Icon(Icons.calendar_month),
                        label: 'Calendar'),
                    NavigationDestination(
                        icon: Icon(Icons.local_fire_department_outlined),
                        selectedIcon: Icon(Icons.local_fire_department),
                        label: 'Habits'),
                    NavigationDestination(
                        icon: Icon(Icons.checklist_rounded),
                        selectedIcon: Icon(Icons.checklist),
                        label: 'Lists'),
                    NavigationDestination(
                        icon: Icon(Icons.apps_outlined),
                        selectedIcon: Icon(Icons.apps),
                        label: 'More'),
                  ],
                ),
              ),
            )
          : NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _onDestinationSelected,
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: 'Home'),
                NavigationDestination(
                    icon: Icon(Icons.list_alt_outlined),
                    selectedIcon: Icon(Icons.list_alt),
                    label: 'Tasks'),
                NavigationDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month),
                    label: 'Calendar'),
                NavigationDestination(
                    icon: Icon(Icons.local_fire_department_outlined),
                    selectedIcon: Icon(Icons.local_fire_department),
                    label: 'Habits'),
                NavigationDestination(
                    icon: Icon(Icons.checklist_rounded),
                    selectedIcon: Icon(Icons.checklist),
                    label: 'Lists'),
                NavigationDestination(
                    icon: Icon(Icons.apps_outlined),
                    selectedIcon: Icon(Icons.apps),
                    label: 'More'),
              ],
            ),
    );
  }
}
