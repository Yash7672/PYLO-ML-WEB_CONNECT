import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/glass_components.dart';
import '../../../models/birthday_model.dart';
import '../../../models/task_model.dart';
import '../../../providers/birthday_provider.dart';
import '../../../providers/focus_provider.dart';
import '../../../providers/task_provider.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/glass_depth.dart';
import '../../birthdays/screens/birthdays_screen.dart';
import '../../focus/screens/focus_screen.dart';
import '../../profile/screens/profile_screen.dart';
import '../../settings/screens/settings_screen.dart';
import '../../tasks/screens/add_edit_task_screen.dart';
import '../../tasks/screens/task_list_screen.dart';
import '../widgets/task_list_item.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todayTasks = ref.watch(todayTasksProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipOval(
              child: Image.asset(
                'assets/logo.png',
                width: 30,
                height: 30,
                fit: BoxFit.cover,
                cacheWidth: 90,
                cacheHeight: 90,
              ),
            ),
            const SizedBox(width: 12),
            const Text('PYLO', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TaskListScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
        ],
      ),
      // CustomScrollView with slivers keeps the today-task rows lazy: only the
      // visible subset is laid out, even on huge task lists.
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: _GreetingHeader()),
          const SliverToBoxAdapter(child: _StreakSummaryCard()),
          const SliverToBoxAdapter(child: _FocusCard()),
          const SliverToBoxAdapter(child: _BirthdaysSection()),
          SliverToBoxAdapter(
              child: _buildSectionHeader(context, 'Today', todayTasks.length)),
          ..._buildTaskSlivers(context, todayTasks),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'dashboard_fab',
        onPressed: () {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (context) => const AddEditTaskScreen()));
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ── Greeting + daily progress (watches todayTasks only) ──────────────

class _GreetingHeader extends ConsumerWidget {
  const _GreetingHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Slice select: the header repaints only when the completed/total pair
    // changes — a toggled subtitle field or reordered list won't redraw it.
    final counts =
        ref.watch(todayTasksProvider.select((todayTasks) {
      var completedCount = 0;
      for (final t in todayTasks) {
        if (t.isCompleted) completedCount++;
      }
      return (completed: completedCount, total: todayTasks.length);
    }));
    final theme = Theme.of(context);

    final completedCount = counts.completed;
    final progress = counts.total == 0
        ? 0
        : (completedCount / counts.total * 100).round();

    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 18
            ? 'Good Afternoon'
            : 'Good Evening';

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greeting,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Stay focused, stay offline, and keep your day on track.',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: isGlassTheme(context)
                      ? GlassColors.textSecondary
                      : Colors.grey[600])),
          const SizedBox(height: 12),
          _glassWrap(
            context,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Daily progress',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text('$completedCount of ${counts.total} done',
                          style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress / 100,
                      minHeight: 10,
                      backgroundColor:
                          theme.colorScheme.surface.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('$progress% complete',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Streak summary (watches streakSummary only) ──────────────────────

class _StreakSummaryCard extends ConsumerWidget {
  const _StreakSummaryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streakSummary = ref.watch(streakSummaryProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GlassSurface(
        borderRadius: 16,
        depth: GlassDepth.level1,
        blur: 0,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.local_fire_department, color: Colors.orange),
                const SizedBox(width: 8),
                Text('Streak momentum',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _chip(theme, 'Active ${streakSummary['activeStreaks'] ?? 0}'),
                _chip(
                    theme, 'Best ${streakSummary['longestStreak'] ?? 0} days'),
                _chip(theme,
                    'Completed today ${streakSummary['completedToday'] ?? 0}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: theme.textTheme.labelMedium),
    );
  }
}



// ── Focus card (watches focusProvider only) ──────────────────────────

class _FocusCard extends ConsumerWidget {
  const _FocusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Select the int so the 1 s focus ticker does not rebuild this card.
    final minutesToday =
        ref.watch(focusProvider.select((s) => s.minutesToday));
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GlassSurface(
        borderRadius: 16,
        depth: GlassDepth.level2,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isGlassTheme(context)
                    ? GlassColors.accentSubtle
                    : Colors.deepPurple.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.timer_outlined,
                  color: isGlassTheme(context)
                      ? GlassColors.accent
                      : Colors.deepPurple),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Focus',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text(
                    minutesToday > 0
                        ? '${minutesToday}m focused today'
                        : 'Start a deep work session',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: isGlassTheme(context)
                            ? GlassColors.textSecondary
                            : Colors.grey[600]),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const FocusScreen())),
              child: const Text('Start'),
            ),
          ],
        ),
      ),
    );
  }
}



// ── Birthdays (today & tomorrow only) ───────────────────────────────

/// Renders ONLY birthdays whose annual date falls on the device's today or
/// tomorrow. Matching ignores the birth year (birthdays repeat every year)
/// and DateTime(y, m, d + 1) keeps the Dec 31 → Jan 1 boundary correct.
class _BirthdaysSection extends ConsumerWidget {
  const _BirthdaysSection();

  static bool _sameDay(Birthday birthday, DateTime date) =>
      birthday.birthDate.month == date.month &&
      birthday.birthDate.day == date.day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final birthdays =
        ref.watch(birthdayProvider.select((s) => s.value ?? const <Birthday>[]));

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);

    final todays = birthdays.where((b) => _sameDay(b, today)).toList();
    final tomorrows = birthdays.where((b) => _sameDay(b, tomorrow)).toList();
    final count = todays.length + tomorrows.length;

    // Keep Home clean: no birthdays today/tomorrow → no section at all.
    if (count == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(context, 'Birthdays', count),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: GlassSurface(
            borderRadius: 16,
            depth: GlassDepth.level1,
            blur: 0,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                for (final b in todays)
                  _birthdayRow(context, b, 'Today'),
                for (final b in tomorrows)
                  _birthdayRow(context, b, 'Tomorrow'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _birthdayRow(BuildContext context, Birthday birthday, String label) {
    final theme = Theme.of(context);
    final isGlass = isGlassTheme(context);
    final accentIcon = isGlass ? GlassColors.accent : Colors.deepPurple;
    final accentFill = isGlass
        ? GlassColors.accentSubtle
        : Colors.deepPurple.withValues(alpha: 0.12);

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const BirthdaysScreen())),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accentFill,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.cake, color: accentIcon, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                birthday.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: accentFill,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$label 🎂',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: accentIcon,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Today tasks ──────────────────────────────────────────────────────

/// Lazy sliver versions of the previously eagerly-built section: only visible
/// rows are mounted, and separators are emitted between items exactly like the
/// old ListView.separated(shrinkWrap: true).
List<Widget> _buildTaskSlivers(BuildContext context, List<Task> tasks) {
  if (tasks.isEmpty) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Center(
              child: Text('No tasks here.',
                  style: TextStyle(
                      color: isGlassTheme(context)
                          ? GlassColors.textMuted
                          : Colors.grey[500]))),
        ),
      ),
    ];
  }
  return [
    SliverList.separated(
      itemCount: tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      // Each row is its own compositing layer: toggling one task (or a Glass
      // blur re-composite behind the list) repaints only that row instead of
      // the whole visible section.
      itemBuilder: (context, index) {
        final task = tasks[index];
        return RepaintBoundary(
          key: ValueKey('today_task_${task.id}'),
          child: TaskListItem(task: task),
        );
      },
    ),
  ];
}



// ── Shared helpers ──────────────────────────────────────────────────

/// Wrap non-glossy Material containers in frosted glass when the Glass theme
/// is active. In every other theme the child passes through unchanged, so
/// Dark / Light / AMOLED keep their exact existing look. Using this helper on
/// the dashboard's decorative containers keeps the ≤3 BackdropFilter budget
/// per screen (only depth levels 1-2 are used here, all non-interactive).
Widget _glassWrap(BuildContext context, {required Widget child}) {
  if (!isGlassTheme(context)) return child;
  return GlassSurface(
    borderRadius: 16,
    depth: GlassDepth.level1,
    padding: EdgeInsets.zero,
    child: child,
  );
}

Widget _buildSectionHeader(BuildContext context, String title, int count) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(count.toString(),
              style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold)),
        )
      ],
    ),
  );
}
