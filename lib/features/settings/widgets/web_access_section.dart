import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../providers/cloud_auth_provider.dart';
import '../../../services/cloud/cloud_config_store.dart';
import '../../../services/cloud/cloud_sync_service.dart';
import '../../../theme/app_theme.dart';
import 'cloud_setup_help_screen.dart';
import 'forgot_password_sheet.dart';

/// Optional Supabase-backed "today's data" sync for the future PYLO website.
///
/// This is a purely *optional* channel: the app's SQLite database stays the
/// single source of truth and never reads the cloud back. The user connects
/// their OWN Supabase project on the Create Account screen; until they do, the
/// whole section simply reports "backup off" and the app runs fully offline.
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
              orElse: () => _content(context, ref, const CloudAuthState()),
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
    final subtitleStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: isGlass ? GlassColors.textMuted : Colors.grey[600]);

    if (state.notConfigured) {
      // No user-configured project — cloud stays fully dormant but the setup
      // entry point (Create Account / Login) stays reachable.
      return Column(
        children: [
          ListTile(
            leading: Icon(Icons.cloud_off_outlined,
                color: isGlass ? GlassColors.textMuted : Colors.grey[600]),
            title: Text('Cloud backup off',
                style: subtitleStyle?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: const Text(
                'No Supabase project is connected, so all data stays on this '
                'device.\nCreate an account and enter your own Project URL and '
                'anon/public key to enable optional cloud backup.'),
          ),
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
                    color:
                        isGlass ? GlassColors.textPrimary : Colors.red[600])),
            subtitle:
                const Text('TODAY\'s cloud copy is removed from the server'),
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
      projectUrl: true,
      anonKey: true,
    );
    _showForm(
      context,
      title: 'Create PYLO cloud account',
      fields: fields.values.toList(),
      submitLabel: 'Create Account',
      cloud: CloudSetupOptions(
        onTest: (url, key) =>
            ref.read(cloudAuthProvider.notifier).testConnection(url, key),
        onChanged: () =>
            ref.read(cloudAuthProvider.notifier).invalidateConnectionTest(),
        onHelp: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const CloudSetupHelpScreen(),
            ),
          );
        },
      ),
      onSubmit: (values) {
        final url = (values[CloudSetupOptions.urlKey] ?? '').trim();
        final key = (values[CloudSetupOptions.keyKey] ?? '').trim();
        final CloudConfig? cloud = (url.isEmpty && key.isEmpty)
            ? null
            : CloudConfig(url: url, anonKey: key);
        return ref.read(cloudAuthProvider.notifier).createAccount(
              values['email']!,
              values['password']!,
              values['confirm']!,
              cloud: cloud,
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
    if (!context.mounted) return;
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
    bool projectUrl = false,
    bool anonKey = false,
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
    if (projectUrl) {
      fields[CloudSetupOptions.urlKey] = _FormField(
        key: CloudSetupOptions.urlKey,
        label: 'Supabase Project URL',
        controller: TextEditingController(),
        keyboardType: TextInputType.url,
      );
    }
    if (anonKey) {
      fields[CloudSetupOptions.keyKey] = _FormField(
        key: CloudSetupOptions.keyKey,
        label: 'Public / Anon Key',
        controller: TextEditingController(),
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
    CloudSetupOptions? cloud,
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
        cloud: cloud,
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
        : (result.ok
            ? 'Done!'
            : '$label: Something went wrong. Please try again.');
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(SnackBar(content: Text(text), backgroundColor: color));
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
      return const ('Cloud sync not configured', Color(0xFFB26A00));
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

/// Modifiers for the Create Account sheet's optional "Connect your own
/// Supabase project" block. Populated only for account creation; every other
/// auth sheet leaves `_AuthFormSheet.cloud` null and is untouched.
class CloudSetupOptions {
  static const String urlKey = 'cloudUrl';
  static const String keyKey = 'cloudKey';

  /// Runs the real connection + table check against the user's project.
  final Future<CloudSyncResult> Function(String url, String anonKey) onTest;

  final VoidCallback? onChanged;

  /// Opens the step-by-step "Help me connect" screen.
  final VoidCallback onHelp;

  const CloudSetupOptions({
    required this.onTest,
    required this.onHelp,
    this.onChanged,
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
  final CloudSetupOptions? cloud;
  final Future<CloudSyncResult> Function(Map<String, String>) onSubmit;

  const _AuthFormSheet({
    required this.title,
    required this.fields,
    required this.submitLabel,
    this.footerBuilder,
    this.cloud,
    required this.onSubmit,
  });

  @override
  State<_AuthFormSheet> createState() => _AuthFormSheetState();
}

class _AuthFormSheetState extends State<_AuthFormSheet> {
  bool _busy = false;
  String? _error;
  CloudSyncErrorKind _errorKind = CloudSyncErrorKind.unknown;

  bool _testBusy = false;
  String? _testMessage;
  bool _testOk = false;
  CloudConfig? _testedConfig;
  int _testGeneration = 0;
  int _submitGeneration = 0;

  Map<String, String> get _values => {
        for (final f in widget.fields) f.key: f.controller.text.trim(),
      };

  String get _cloudUrl {
    final field = _field(CloudSetupOptions.urlKey);
    return field?.controller.text.trim() ?? '';
  }

  String get _cloudKey {
    final field = _field(CloudSetupOptions.keyKey);
    return field?.controller.text.trim() ?? '';
  }

  CloudConfig get _currentCloudConfig => CloudConfig(
        url: _cloudUrl,
        anonKey: _cloudKey,
      );

  bool get _hasCloudConfig => _cloudUrl.isNotEmpty || _cloudKey.isNotEmpty;

  bool get _cloudTestIsCurrent {
    final tested = _testedConfig;
    return _testOk && tested != null && tested.sameAs(_currentCloudConfig);
  }

  _FormField? _field(String key) {
    for (final f in widget.fields) {
      if (f.key == key) return f;
    }
    return null;
  }

  void _clearCloudTest() {
    if (!mounted) return;
    _testGeneration++;
    _submitGeneration++;
    widget.cloud?.onChanged?.call();
    if (!_testOk && _testedConfig == null && _testMessage == null) return;
    setState(() {
      _testOk = false;
      _testedConfig = null;
      _testMessage = null;
    });
  }

  Future<void> _testCloud() async {
    if (_testBusy || _busy) return;
    final candidate = _currentCloudConfig;
    final configError = candidate.validationError;
    if (configError != null) {
      _testGeneration++;
      widget.cloud?.onChanged?.call();
      if (!mounted) return;
      setState(() {
        _testMessage = configError;
        _testOk = false;
        _testedConfig = null;
      });
      return;
    }
    final generation = ++_testGeneration;
    setState(() {
      _testBusy = true;
      _testMessage = null;
      _error = null;
    });
    CloudSyncResult result;
    try {
      result = await widget.cloud!.onTest(candidate.url, candidate.anonKey);
    } catch (_) {
      result = const CloudSyncResult.fail(
        CloudSyncErrorKind.unknown,
        'Could not test the project connection.',
      );
    }
    if (!mounted) return;
    if (generation != _testGeneration) {
      setState(() {
        _testBusy = false;
        _testOk = false;
        _testedConfig = null;
        _testMessage = null;
      });
      return;
    }
    setState(() {
      _testBusy = false;
      _testOk = result.ok;
      _testedConfig = result.ok ? candidate : null;
      _testMessage = result.message.isEmpty
          ? (result.ok ? 'Connected' : 'Could not connect.')
          : result.message;
    });
  }

  Future<void> _submit() async {
    if (_busy || _testBusy) return;
    if (widget.cloud != null && _hasCloudConfig) {
      if (_cloudUrl.isEmpty || _cloudKey.isEmpty) {
        setState(() {
          _error = 'Enter both the Project URL and the anon/public key, or '
              'leave both empty for a fully offline account.';
          _errorKind = CloudSyncErrorKind.invalidCredentials;
        });
        return;
      }
      if (!_cloudTestIsCurrent) {
        setState(() {
          _error = 'Test this exact Project URL and anon/public key before '
              'creating the account.';
          _errorKind = CloudSyncErrorKind.invalidCredentials;
        });
        return;
      }
    }
    final generation = ++_submitGeneration;
    setState(() {
      _busy = true;
      _error = null;
    });
    CloudSyncResult result;
    try {
      result = await widget.onSubmit(_values);
    } catch (_) {
      result = const CloudSyncResult.fail(
        CloudSyncErrorKind.unknown,
        'Could not create the account. Please try again.',
      );
    }
    if (!mounted) return;
    if (generation != _submitGeneration) {
      setState(() {
        _busy = false;
      });
      return;
    }
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

  Widget _cloudSection(BuildContext context) {
    final isGlass = isGlassTheme(context);
    final headingStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.bold,
        color: isGlass ? GlassColors.textPrimary : null);
    final urlController = _field(CloudSetupOptions.urlKey)?.controller;
    final keyController = _field(CloudSetupOptions.keyKey)?.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Cloud backup (optional)', style: headingStyle),
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: widget.cloud!.onHelp,
              icon: const Icon(Icons.help_outline, size: 18),
              label: const Text('Help me connect'),
            ),
          ],
        ),
        AbsorbPointer(
          absorbing: _busy || _testBusy,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GlassInput(
                controller: urlController,
                labelText: 'Supabase Project URL',
                hintText: 'https://xxxx.supabase.co',
                prefixIcon: Icons.link_outlined,
                keyboardType: TextInputType.url,
                onChanged: (_) => _clearCloudTest(),
              ),
              const SizedBox(height: 12),
              GlassInput(
                controller: keyController,
                labelText: 'Public / Anon Key',
                hintText: 'eyJhbGciOiJIUzI1NiIs...',
                prefixIcon: Icons.key_outlined,
                onChanged: (_) => _clearCloudTest(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GlassButton(
              outlined: true,
              onPressed: _testBusy || _busy ? null : _testCloud,
              child: _testBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Test'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _testMessage == null
                  ? Text('Leave blank for a fully offline account.',
                      style: TextStyle(
                          fontSize: 12,
                          color: isGlass
                              ? GlassColors.textMuted
                              : Colors.grey[600]))
                  : Text(
                      _testMessage!,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _testOk
                              ? (isGlass
                                  ? Colors.lightGreenAccent
                                  : Colors.green)
                              : Colors.redAccent),
                    ),
            ),
          ],
        ),
      ],
    );
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
                      color: isGlass ? GlassColors.textPrimary : null)),
              const SizedBox(height: 16),
              for (final f in widget.fields)
                if (widget.cloud == null ||
                    (f.key != CloudSetupOptions.urlKey &&
                        f.key != CloudSetupOptions.keyKey)) ...[
                  GlassInput(
                    controller: f.controller,
                    labelText: f.label,
                    obscureText: f.obscure,
                    keyboardType: f.keyboardType,
                  ),
                  const SizedBox(height: 12),
                ],
              if (widget.cloud != null) ...[
                _cloudSection(context),
                const SizedBox(height: 16),
              ],
              if (widget.footerBuilder != null) ...[
                widget.footerBuilder!(_busy),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                Text(
                    '${_resultPresentation(CloudSyncResult.fail(_errorKind)).$1}:\n$_error',
                    style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 12),
              ],
              GlassButton(
                onPressed: _busy || _testBusy ? null : _submit,
                child: _busy
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: isGlassTheme(context)
                                ? GlassColors.onAccent
                                : Theme.of(context).colorScheme.onPrimary))
                    : Text(widget.submitLabel),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed:
                    _busy || _testBusy ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
