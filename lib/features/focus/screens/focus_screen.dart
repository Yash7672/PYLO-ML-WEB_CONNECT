import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/glass_components.dart';
import '../../../models/focus_session_model.dart';
import '../../../providers/focus_provider.dart';
import '../../../providers/task_provider.dart';
import '../../../theme/app_theme.dart';
import 'focus_active_screen.dart';

class FocusScreen extends ConsumerStatefulWidget {
  const FocusScreen({super.key});

  static const presetDurations = [15, 25, 30, 45, 60];

  @override
  ConsumerState<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends ConsumerState<FocusScreen> {
  bool _navigatedToActive = false;

  @override
  Widget build(BuildContext context) {
    // Select only what the shell needs: during an active session the provider
    // emits a new FocusState on every minute boundary; slicing keeps this
    // screen from rebuilding 60×/h for time that only FocusTimer displays.
    final isLoading = ref.watch(focusProvider.select((s) => s.isLoading));
    final active = ref.watch(focusProvider.select((s) => s.active));

    if (isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Focus Mode')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (active != null && !_navigatedToActive) {
      _navigatedToActive = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const FocusActiveScreen()),
          );
        }
      });
      return Scaffold(
        appBar: AppBar(title: const Text('Focus Mode')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Focus Mode'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => _showHistory(context, ref),
          ),
        ],
      ),
      body: const _SetupView(),
    );
  }

  void _showHistory(BuildContext context, WidgetRef ref) {
    final focus = ref.read(focusProvider);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final sessions = focus.history;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text('Focus History',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Today: ${_formatMinutes(focus.minutesToday)} focused',
                  style: TextStyle(
                      color: isGlassTheme(context)
                          ? GlassColors.textSecondary
                          : Colors.grey[600])),
              const SizedBox(height: 12),
              if (sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text('No sessions yet.',
                        style: TextStyle(
                            color: isGlassTheme(context)
                                ? GlassColors.textSecondary
                                : Colors.grey[600])),
                  ),
                )
              else
                ...sessions.take(20).map((s) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        s.completed
                            ? Icons.check_circle
                            : Icons.stop_circle_outlined,
                        color: s.completed
                            ? Colors.green
                            : (isGlassTheme(context)
                                ? GlassColors.textMuted
                                : Colors.grey),
                      ),
                      title: Text(s.label.isEmpty ? 'Focus session' : s.label),
                      subtitle: Text(
                          '${_formatMinutes(s.actualMinutes)} • ${s.startTime.day}/${s.startTime.month} '
                          '${s.startTime.hour.toString().padLeft(2, '0')}:${s.startTime.minute.toString().padLeft(2, '0')}'),
                      trailing: s.mode == FocusMode.strict
                          ? const Icon(Icons.lock, size: 16)
                          : null,
                    )),
            ],
          ),
        );
      },
    );
  }

  static String _formatMinutes(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

class _SetupView extends ConsumerStatefulWidget {
  const _SetupView();

  @override
  ConsumerState<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends ConsumerState<_SetupView> {
  // Guards against double-pushing FocusActiveScreen when the Start button is
  // tapped rapidly before the first push completes.
  bool _startingFocus = false;
  int _selectedMinutes = 25;
  bool _isCustomDuration = false;
  final TextEditingController _customDurationController =
      TextEditingController();
  String? _selectedTaskId;
  late TextEditingController _labelController;
  late FocusMode _selectedMode;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController();
    final focusState = ref.read(focusProvider);
    _selectedMode = focusState.isStrictMode
        ? FocusMode.strict
        : FocusMode.normal;
  }

  @override
  void dispose() {
    _labelController.dispose();
    _customDurationController.dispose();
    super.dispose();
  }

  int get _effectiveMinutes {
    if (_isCustomDuration) {
      final parsed = int.tryParse(_customDurationController.text);
      if (parsed != null && parsed >= 1 && parsed <= 480) return parsed;
      return 25;
    }
    return _selectedMinutes;
  }

  @override
  Widget build(BuildContext context) {
    final todayTasks = ref.watch(todayTasksProvider);
    final pendingTasks =
        todayTasks.where((t) => !t.isCompleted).toList();

    ref.listen(todayTasksProvider, (prev, next) {
      final pending = next.where((t) => !t.isCompleted).toList();
      if (_selectedTaskId != null &&
          !pending.any((t) => t.id == _selectedTaskId)) {
        _selectedTaskId = null;
        _labelController.clear();
      }
    });
    final selectedTask =
        pendingTasks.where((t) => t.id == _selectedTaskId).firstOrNull;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mode',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _ModeCard(
                          icon: Icons.psychology,
                          title: 'Normal',
                          subtitle: 'Light restrictions',
                          isSelected: _selectedMode == FocusMode.normal,
                          onTap: () =>
                              setState(() => _selectedMode = FocusMode.normal),
                          theme: Theme.of(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ModeCard(
                          icon: Icons.lock_outline,
                          title: 'Strict',
                          subtitle: 'PIN to end early',
                          isSelected: _selectedMode == FocusMode.strict,
                          onTap: () =>
                              setState(() => _selectedMode = FocusMode.strict),
                          theme: Theme.of(context),
                          accentColor: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Duration',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ...FocusScreen.presetDurations.map((m) => ChoiceChip(
                            label: Text('$m min'),
                            selected:
                                !_isCustomDuration && _selectedMinutes == m,
                            onSelected: (_) => setState(() {
                              _selectedMinutes = m;
                              _isCustomDuration = false;
                            }),
                          )),
                      ChoiceChip(
                        label: const Text('Custom'),
                        selected: _isCustomDuration,
                        onSelected: (_) => setState(() {
                          _isCustomDuration = true;
                        }),
                      ),
                    ],
                  ),
                  if (!_isCustomDuration) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _selectedMinutes.toDouble(),
                            min: 5,
                            max: 120,
                            divisions: 23,
                            label: '$_selectedMinutes min',
                            onChanged: (value) => setState(
                                () => _selectedMinutes = value.round()),
                          ),
                        ),
                        SizedBox(
                          width: 60,
                          child: Text('$_selectedMinutes min',
                              textAlign: TextAlign.end,
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                      ],
                    ),
                  ],
                  if (_isCustomDuration) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _customDurationController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Minutes (1 - 480)',
                        border: OutlineInputBorder(),
                        suffixText: 'min',
                      ),
                      // No onChanged → no setState: the parsed value is only
                      // read when the user taps Start (_startFocus), so a
                      // per-keystroke rebuild of the entire setup form is pure
                      // waste (it rebuilds the task dropdown + mode cards).
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('What are you focusing on?',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: const InputDecoration(
                        labelText: 'Pick a task (optional)',
                        border: OutlineInputBorder()),
                    child: DropdownButton<String>(
                      key: ValueKey(_selectedTaskId),
                      value: _selectedTaskId,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      items: pendingTasks
                          .map((t) => DropdownMenuItem(
                              value: t.id, child: Text(t.title)))
                          .toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedTaskId = value;
                          if (value != null) {
                            final task = pendingTasks
                                .where((t) => t.id == value)
                                .firstOrNull;
                            if (task != null) {
                              _labelController.text = task.title;
                            }
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _labelController,
                    decoration: const InputDecoration(
                        labelText: 'Or type a label',
                        border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _startFocus(selectedTask?.title),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 18),
              backgroundColor: isGlassTheme(context)
                  ? Theme.of(context).colorScheme.primary
                  : Colors.deepPurple,
              foregroundColor: isGlassTheme(context)
                  ? GlassColors.onAccent
                  : null,
            ),
            icon: Icon(
              _selectedMode == FocusMode.strict
                  ? Icons.lock_outline
                  : Icons.play_arrow_rounded,
              size: 28,
            ),
            label: Text(
              _selectedMode == FocusMode.strict
                  ? 'START STRICT FOCUS'
                  : 'START FOCUS',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'Calls and notifications still arrive.\nPYLO just helps you stay on one thing.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isGlassTheme(context)
                      ? GlassColors.textSecondary
                      : Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startFocus(String? taskTitle) async {
    if (_startingFocus) return;
    _startingFocus = true;
    try {
      final label = taskTitle ??
          (_labelController.text.trim().isNotEmpty
              ? _labelController.text.trim()
              : 'Focus session');

      await ref.read(focusProvider.notifier).startFocus(
            label: label,
            taskId: _selectedTaskId,
            minutes: _effectiveMinutes,
            mode: _selectedMode,
          );

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FocusActiveScreen()),
        );
      }
    } finally {
      _startingFocus = false;
    }
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;
  final ThemeData theme;
  final Color? accentColor;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
    required this.theme,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? theme.colorScheme.tertiary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.1)
              : theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? color : theme.colorScheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
                icon,
                size: 32,
                color: isSelected
                    ? color
                    : (isGlassTheme(context)
                        ? GlassColors.textMuted
                        : Colors.grey),
              ),
            const SizedBox(height: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: isSelected ? color : null,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
