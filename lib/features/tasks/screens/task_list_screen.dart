import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/task_provider.dart';
import '../../dashboard/widgets/task_list_item.dart';

class TaskListScreen extends ConsumerStatefulWidget {
  const TaskListScreen({super.key});

  @override
  ConsumerState<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends ConsumerState<TaskListScreen> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filterState = ref.watch(taskFilterStateProvider);
    final filteredTasks = ref.watch(filteredTaskListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tasks')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search tasks',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  // Guard against async firing if the screen is popped while
                  // the debounce window is still running.
                  if (!mounted) return;
                  // Re-read the CURRENT filter state at fire time: a 300 ms-old
                  // snapshot would otherwise revert a filter or archived toggle
                  // the user changed while the debounce was pending.
                  ref.read(taskFilterStateProvider.notifier).state = ref
                      .read(taskFilterStateProvider)
                      .copyWith(queryLower: value.toLowerCase());
                });
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: InputDecorator(
              decoration: const InputDecoration(
                  labelText: 'Filter', border: OutlineInputBorder()),
              child: DropdownButton<String>(
                value: filterState.filter,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'Today', child: Text('Today')),
                  DropdownMenuItem(value: 'All', child: Text('All')),
                  DropdownMenuItem(value: 'Completed', child: Text('Completed')),
                  DropdownMenuItem(value: 'Pending', child: Text('Pending')),
                  DropdownMenuItem(value: 'Favorites', child: Text('Favorites')),
                  DropdownMenuItem(value: 'Pinned', child: Text('Pinned')),
                  DropdownMenuItem(value: 'Archived', child: Text('Archived')),
                ],
                onChanged: (value) {
                  ref.read(taskFilterStateProvider.notifier).state =
                      filterState.copyWith(filter: value ?? 'All');
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show archived tasks'),
              value: filterState.showArchived,
              onChanged: (value) {
                ref.read(taskFilterStateProvider.notifier).state =
                    filterState.copyWith(showArchived: value);
              },
            ),
          ),
          Expanded(
            child: filteredTasks.isEmpty
                ? const Center(child: Text('No tasks match your search.'))
                : ListView.builder(
                    itemCount: filteredTasks.length,
                    itemBuilder: (context, index) =>
                        TaskListItem(task: filteredTasks[index]),
                  ),
          ),
        ],
      ),
    );
  }
}
