import 'package:flutter/material.dart';

import '../../../core/widgets/glass_components.dart';
import '../../../models/birthday_model.dart';
import '../../../theme/app_theme.dart';

class BirthdayCard extends StatelessWidget {
  final Birthday birthday;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const BirthdayCard({
    super.key,
    required this.birthday,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = birthday.daysUntilNext();
    final isToday = days == 0;
    final isSoon = days > 0 && days <= 7;

    final Color accent = isToday
        ? Colors.pink
        : isSoon
            ? Colors.orange
            : theme.colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        side: BorderSide(
          color: isToday || isSoon ? accent.withValues(alpha: 0.5) : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: const BorderRadius.all(Radius.circular(14)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${birthday.birthDate.day}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold, color: accent),
              ),
              Text(
                _monthShort(birthday.birthDate.month),
                style: theme.textTheme.labelSmall?.copyWith(color: accent),
              ),
            ],
          ),
        ),
        title: Text(birthday.name,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              isToday
                  ? 'Today!'
                  : days == 1
                      ? 'Tomorrow'
                      : 'In $days days',
              style: TextStyle(
                  color: accent, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            if (birthday.phone.isNotEmpty)
              Text(birthday.phone,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: isGlassTheme(context)
                          ? GlassColors.textSecondary
                          : Colors.grey[600])),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') onEdit();
            if (value == 'delete') onDelete();
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  String _monthShort(int month) => switch (month) {
        1 => 'JAN', 2 => 'FEB', 3 => 'MAR', 4 => 'APR',
        5 => 'MAY', 6 => 'JUN', 7 => 'JUL', 8 => 'AUG',
        9 => 'SEP', 10 => 'OCT', 11 => 'NOV', _ => 'DEC',
      };
}
