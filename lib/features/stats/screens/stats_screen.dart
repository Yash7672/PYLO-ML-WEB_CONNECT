import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/focus_provider.dart';
import '../../../providers/task_provider.dart';

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Narrow selects so this screen only rebuilds when the exact values it
    // renders actually change (a task mutating another field, or a focus
    // session ticking, must not repaint these cards).
    final counts = ref.watch(allTasksProvider.select((tasks) {
      var completed = 0;
      var total = 0;
      for (final task in tasks) {
        if (task.isArchived) continue;
        total++;
        if (task.isCompleted) completed++;
      }
      return (completed: completed, total: total);
    }));
    final streakStats = ref.watch(overallStatsProvider);
    // 'Active Streaks' must be habits currently on a streak, not the raw habit
    // count that overallStats' totalStreaks exposes.
    final activeStreaks =
        ref.watch(streakSummaryProvider.select((s) => s['activeStreaks'] ?? 0));
    final minutesToday =
        ref.watch(focusProvider.select((s) => s.minutesToday));
    final sessionCount =
        ref.watch(focusProvider.select((s) => s.history.length));
    final theme = Theme.of(context);

    final completed = counts.completed;
    final total = counts.total;
    final pending = total - completed;

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Productivity Overview',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _statCard(context, Icons.check_circle_outline, Colors.green,
              'Completed', '$completed'),
          _statCard(context, Icons.pending_outlined, Colors.orange,
              'Pending', '$pending'),
          _statCard(context, Icons.list_alt_rounded, Colors.blue,
              'Total Tasks', '$total'),
          const SizedBox(height: 24),
          Row(
            children: [
              const Icon(Icons.local_fire_department,
                  color: Colors.deepOrange, size: 24),
              const SizedBox(width: 8),
              Text('Streaks',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          _statCard(context, Icons.local_fire_department, Colors.deepOrange,
              'Active Streaks', '$activeStreaks'),
          _statCard(context, Icons.emoji_events_outlined, Colors.amber,
              'Best Streak Ever', '${streakStats['bestStreakEver']} days'),
          _statCard(context, Icons.show_chart, Colors.teal,
              'Average Streak', '${(streakStats['averageStreak'] ?? 0.0).toStringAsFixed(1)} days'),
          const SizedBox(height: 24),
          Text('Focus',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _statCard(context, Icons.timer_outlined, Colors.deepPurple,
              'Focus Today', _formatMinutes(minutesToday)),
          _statCard(context, Icons.history_rounded, Colors.indigo,
              'Sessions Logged', '$sessionCount'),
        ],
      ),
    );
  }

  String _formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  Widget _statCard(BuildContext context, IconData icon, Color color,
      String title, String value) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.13),
            borderRadius: const BorderRadius.all(Radius.circular(10)),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(title),
        trailing: Text(value,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
      ),
    );
  }
}
