import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../providers/cloud_auth_provider.dart';
import '../../../services/cloud/cloud_sync_service.dart';
import '../../../theme/app_theme.dart';
import 'forgot_password_sheet.dart';

/// Optional Supabase-backed "today's data" sync for the future PYLO website.
///
/// This is a purely *optional* channel: the app's SQLite database stays the
/// single source of truth and never reads the cloud back. Everything here is
/// guarded by a build-time publishable key; without it the whole section
/// simply reports "not enabled" and the app runs fully offline as before.
class WebAccessSection extends ConsumerWidget {
  const WebAccessSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudAuthProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, 'Web Access'),
          Card(
            child: state.maybeWhen(
              loading: () => const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              ),
              data: (s) => _content(context, ref, s),
              orElse: () =>
                  _content(context, ref, const CloudAuthState()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String title) {
    final isGlass = isGlassTheme(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: isGlass ? GlassColors.textMuted : Colors.grey[600])),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, CloudAuthState state) {
    final isGlass = isGlassTheme(context);
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    final subtitleStyle =
        Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isGlass ? GlassColors.textMuted : Colors.grey[600]);

    if (state.notConfigured) {
      // Built without the publishable key — cloud stays fully dormant.
      return ListTile(
        leading: Icon(Icons.cloud_off_outlined,
            color: isGlass ? GlassColors.textMuted : Colors.grey[600]),
        title: Text('Cloud sync not enabled',
            style: subtitleStyle?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: const Text(
            'This build has no Supabase publishable key, so cloud sync is off.\n'
            'Rebuild with --dart-define=SUPABASE_ANON_KEY=... to enable.'),
      );
    }

    if (state.busy && state.email == null) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (state.isConnected) {
      return Column(
        children: [
          ListTile(
            leading: Icon(Icons.cloud_done_outlined,
                color: isGlass ? GlassColors.accent : Colors.green),
            title: Text('Connected', style: titleStyle),
            subtitle: Text(state.email!,
                style: subtitleStyle?.copyWith(fontWeight: FontWeight.w600)),
            trailing: state.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Change password'),
            subtitle: const Text('Update your account password'),
            trailing: const Icon(Icons.chevron_right),
            onTap: state.busy ? null : () => _changePassword(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Change Gmail / Email'),
            subtitle: const Text('Update the email of your account'),
            trailing: const Icon(Icons.chevron_right),
            onTap: state.busy ? null : () => _changeEmail(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: Text('Log out',
                style: TextStyle(
                    color: isGlass ? GlassColors.textPrimary : Colors.red[600])),
            subtitle: const Text(
                'TODAY\'s cloud copy is removed from the server'),
            trailing: const Icon(Icons.chevron_right),
            onTap: state.busy ? null : () => _logout(context, ref),
          ),
        ],
      );
    }

    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.cloud_outlined,
              color: isGlass ? GlassColors.textMuted : Colors.grey[600]),
          title: Text('Not connected', style: titleStyle),
          subtitle: const Text(
              'Log in to upload TODAY\'s tasks, quick checklists & checklist '
              'items to your personal PYLO web profile.\n'
              'All local data stays on this device.'),
        ),
        if (state.busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: GlassButton(
                    outlined: true,
                    onPressed: () => _login(context, ref),
                    child: const Text('Login'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassButton(
                    onPressed: () => _createAccount(context, ref),
                    child: const Text('Create Account'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────

  Future<void> _createAccount(BuildContext context, WidgetRef ref) async {
    final fields = _buildFields(
      email: true,
      password: true,
      confirm: true,
    );
    _showForm(
      context,
      title: 'Create PYLO cloud account',
      fields: fields.values.toList(),
      submitLabel: 'Create Account',
      onSubmit: (values) {
        return ref
            .read(cloudAuthProvider.notifier)
            .createAccount(
              values['email']!,
              values['password']!,
              values['confirm']!,
            );
      },
    );
  }

  Future<void> _login(BuildContext context, WidgetRef ref) async {
    final fields = _buildFields(email: true, password: true);
    _showForm(
      context,
      title: 'Log in to PYLO web',
      fields: fields.values.toList(),
      submitLabel: 'Log in',
      footerBuilder: (busy) => Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: busy ? null : () => _forgotPassword(context, ref),
          child: const Text('Forgot Password?'),
        ),
      ),
      onSubmit: (values) {
        return ref
            .read(cloudAuthProvider.notifier)
            .login(values['email']!, values['password']!);
      },
    );
  }

  Future<void> _forgotPassword(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(cloudAuthProvider.notifier);
    final result = await showForgotPasswordFlow(
      context,
      ForgotPasswordFlowApi(
        sendOtp: notifier.forgotPassword,
        verifyOtp: notifier.verifyRecoveryOtp,
        setPassword: notifier.setPasswordAfterRecovery,
      ),
    );
    if (result != null && context.mounted) {
      _showResult(context, result);
    }
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final fields = _buildFields(
      currentPassword: true,
      newPassword: true,
      confirmNewPassword: true,
    );
    _showForm(
      context,
      title: 'Change password',
      fields: fields.values.toList(),
      submitLabel: 'Update password',
      onSubmit: (values) {
        return ref.read(cloudAuthProvider.notifier).changePassword(
              values['currentPassword']!,
              values['newPassword']!,
            );
      },
    );
  }

  Future<void> _changeEmail(BuildContext context, WidgetRef ref) async {
    final fields = _buildFields(newEmail: true, currentPassword: true);
    _showForm(
      context,
      title: 'Change Gmail / Email',
      fields: fields.values.toList(),
      submitLabel: 'Update email',
      onSubmit: (values) {
        return ref.read(cloudAuthProvider.notifier).changeEmail(
              values['newEmail']!,
              values['currentPassword']!,
            );
      },
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showGlassDialog<bool>(
      context,
      title: 'Log out of PYLO web?',
      content: const Text(
          'TODAY\'s cloud copy (tasks, quick checklists, checklist items) '
          'will be deleted from the server.\n\nYour device data stays '
          'untouched.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Log out'),
        ),
      ],
    );
    if (confirmed != true || !context.mounted) return;
    final result = await ref.read(cloudAuthProvider.notifier).logout();
    _showResult(context, result);
  }

  // ── Shared form plumbing ─────────────────────────────────────────────

  Map<String, _FormField> _buildFields({
    bool email = false,
    bool newEmail = false,
    bool password = false,
    bool confirm = false,
    bool currentPassword = false,
    bool newPassword = false,
    bool confirmNewPassword = false,
  }) {
    final fields = <String, _FormField>{};
    if (email) {
      fields['email'] = _FormField(
        key: 'email',
        label: 'Email address',
        controller: TextEditingController(),
        keyboardType: TextInputType.emailAddress,
      );
    }
    if (newEmail) {
      fields['newEmail'] = _FormField(
        key: 'newEmail',
        label: 'New Gmail / Email',
        controller: TextEditingController(),
        keyboardType: TextInputType.emailAddress,
      );
    }
    if (password) {
      fields['password'] = _FormField(
        key: 'password',
        label: 'Password',
        controller: TextEditingController(),
        obscure: true,
      );
    }
    if (currentPassword) {
      fields['currentPassword'] = _FormField(
        key: 'currentPassword',
        label: 'Current password',
        controller: TextEditingController(),
        obscure: true,
      );
    }
    if (newPassword) {
      fields['newPassword'] = _FormField(
        key: 'newPassword',
        label: 'New password',
        controller: TextEditingController(),
        obscure: true,
      );
    }
    if (confirm) {
      fields['confirm'] = _FormField(
        key: 'confirm',
        label: 'Confirm password',
        controller: TextEditingController(),
        obscure: true,
      );
    }
    if (confirmNewPassword) {
      fields['confirmNewPassword'] = _FormField(
        key: 'confirmNewPassword',
        label: 'Confirm new password',
        controller: TextEditingController(),
        obscure: true,
      );
    }
    return fields;
  }

  void _showForm(
    BuildContext context, {
    required String title,
    required List<_FormField> fields,
    required String submitLabel,
    Widget Function(bool busy)? footerBuilder,
    required Future<CloudSyncResult> Function(Map<String, String> values)
        onSubmit,
  }) {
    showGlassBottomSheet<CloudSyncResult>(
      context,
      isScrollControlled: true,
      child: _AuthFormSheet(
        title: title,
        fields: fields,
        submitLabel: submitLabel,
        footerBuilder: footerBuilder,
        onSubmit: (values) {
          final map = <String, String>{};
          for (final f in fields) {
            map[f.key] = values[f.key] ?? '';
          }
          return onSubmit(map);
        },
      ),
    ).then((result) {
      if (result != null && context.mounted) {
        _showResult(context, result);
      }
    });
  }

  void _showResult(BuildContext context, CloudSyncResult result) {
    final messenger = ScaffoldMessenger.of(context);
    final (label, color) = _resultPresentation(result);
    final text = result.message.isNotEmpty
        ? (result.ok ? result.message : '$label:\n${result.message}')
        : (result.ok ? 'Done!' : '$label: Something went wrong. Please try again.');
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
  }
}

/// Maps the four diagnostic buckets the user is expected to see to a
/// short headline + color:
///   - no internet / cloud host unreachable
///   - Supabase configuration missing
///   - Supabase authentication error
///   - Supabase request/server error
(String, Color) _resultPresentation(CloudSyncResult result) {
  switch (result.error) {
    case CloudSyncErrorKind.network:
      return ('No internet / cloud server unreachable', Colors.red);
    case CloudSyncErrorKind.notConfigured:
      return ('Cloud sync not configured', Color(0xFFB26A00));
    case CloudSyncErrorKind.server:
      return ('Cloud server error', Colors.deepOrange);
    case CloudSyncErrorKind.invalidCredentials:
    case CloudSyncErrorKind.emailTaken:
    case CloudSyncErrorKind.weakPassword:
    case CloudSyncErrorKind.invalidEmail:
    case CloudSyncErrorKind.sessionExpired:
      return ('Cloud authentication error', Colors.orange);
    case CloudSyncErrorKind.none:
      return ('Done', Colors.green);
    default:
      return ('Cloud sync', Colors.red);
  }
}

/// A single labelled, controllable input inside an auth sheet.
class _FormField {
  final String key;
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;

  _FormField({
    required this.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
  });
}

/// Modal bottom-sheet form used by every WEB ACCESS action. Disposes its
/// controllers on exit via [DisposeOnExit]. Keeps the sheet open on failure
/// (inline message) and pops with the result on success.
class _AuthFormSheet extends StatefulWidget {
  final String title;
  final List<_FormField> fields;
  final String submitLabel;
  final Widget Function(bool busy)? footerBuilder;
  final Future<CloudSyncResult> Function(Map<String, String>) onSubmit;

  const _AuthFormSheet({
    required this.title,
    required this.fields,
    required this.submitLabel,
    this.footerBuilder,
    required this.onSubmit,
  });

  @override
  State<_AuthFormSheet> createState() => _AuthFormSheetState();
}

class _AuthFormSheetState extends State<_AuthFormSheet> {
  bool _busy = false;
  String? _error;
  CloudSyncErrorKind _errorKind = CloudSyncErrorKind.unknown;

  Map<String, String> get _values => {
        for (final f in widget.fields) f.key: f.controller.text.trim(),
      };

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.onSubmit(_values);
    if (!mounted) return;
    if (result.ok) {
      Navigator.pop(context, result);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.message;
      _errorKind = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isGlass = isGlassTheme(context);
    return DisposeOnExit(
      controllers: [for (final f in widget.fields) f.controller],
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isGlass
                          ? GlassColors.textPrimary
                          : null)),
              const SizedBox(height: 16),
              for (final f in widget.fields) ...[
                GlassInput(
                  controller: f.controller,
                  labelText: f.label,
                  obscureText: f.obscure,
                  keyboardType: f.keyboardType,
                ),
                const SizedBox(height: 12),
              ],
              if (widget.footerBuilder != null) ...[
                widget.footerBuilder!(_busy),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                Text(
                  '${_resultPresentation(CloudSyncResult.fail(_errorKind)).$1}:\n$_error',
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
                const SizedBox(height: 12),
              ],
              GlassButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(widget.submitLabel),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}