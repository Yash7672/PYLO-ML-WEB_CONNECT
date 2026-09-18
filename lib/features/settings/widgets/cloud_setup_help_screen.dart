import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/glass_components.dart';
import '../../../services/cloud/cloud_setup_sql.dart';
import '../../../theme/app_theme.dart';

/// "Help me connect" page opened from the Create Account sheet. Walks the user
/// through creating their own free Supabase project and runs the three SQL
/// blocks PYLO needs, each with its own copy button.
class CloudSetupHelpScreen extends StatefulWidget {
  const CloudSetupHelpScreen({super.key});

  @override
  State<CloudSetupHelpScreen> createState() => _CloudSetupHelpScreenState();
}

class _CloudSetupHelpScreenState extends State<CloudSetupHelpScreen> {
  Future<void> _copy(String blockLabel, String sql) async {
    await Clipboard.setData(ClipboardData(text: sql));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$blockLabel - SQL copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final isGlass = isGlassTheme(context);
    return Scaffold(
      backgroundColor: isGlass ? GlassColors.bg : null,
      appBar: AppBar(title: const Text('Set up cloud backup')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _stepRow(
            'Step 1',
            'Go to supabase.com and create a free account.',
          ),
          _stepRow(
            'Step 2',
            'Click "New project". Give it any name, set a database password and '
            'choose the region closest to you, then click "Create new project".',
          ),
          _stepRow(
            'Step 3',
            'Once the project is ready, open Project Settings → API. Copy the '
            '"Project URL" (https://<ref>.supabase.co) and the "anon" / "public" '
            'key.',
          ),
          _stepRow(
            'Step 4',
            'Open SQL Editor, then paste and run the blocks below — Start with '
            'Step 5, then Step 6, then Step 7.',
          ),
          const SizedBox(height: 16),
          _sqlBlock(context, 'Step 5', 'Create profiles table',
              createProfilesTableSql),
          const SizedBox(height: 16),
          _sqlBlock(context, 'Step 6', 'Create daily_data table',
              createDailyDataTableSql),
          const SizedBox(height: 16),
          _sqlBlock(context, 'Step 7', 'Enable RLS + policies',
              enableRlsAndPoliciesSql),
        ],
      ),
    );
  }

  Widget _stepRow(String title, String body) {
    final isGlass = isGlassTheme(context);
    final muted = isGlass ? GlassColors.textMuted : Colors.grey[600];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isGlass ? GlassColors.accent : Colors.grey.shade200,
              shape: BoxShape.circle,
            ),
            child: Text(
              title.split(' ').last,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color:
                    isGlass ? GlassColors.onAccent : Colors.grey.shade700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body, style: TextStyle(fontSize: 13, color: muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sqlBlock(
    BuildContext context,
    String blockLabel,
    String title,
    String sql,
  ) {
    final isGlass = isGlassTheme(context);
    final muted = isGlass ? GlassColors.textMuted : Colors.grey[600];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$blockLabel) $title',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              tooltip: 'Copy SQL',
              onPressed: () => _copy(blockLabel, sql),
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isGlass ? GlassColors.surfaceOpaqueDark : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isGlass ? GlassColors.border : Colors.grey.shade300,
            ),
          ),
          child: SelectionArea(
            child: Text(
              sql,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.4,
                color: muted,
              ),
            ),
          ),
        ),
      ],
    );
  }
}