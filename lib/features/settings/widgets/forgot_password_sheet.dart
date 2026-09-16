import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/widgets/dialog_disposer.dart';
import '../../../core/widgets/glass_components.dart';
import '../../../services/cloud/cloud_sync_service.dart';
import '../../../theme/app_theme.dart';

/// Callbacks the OTP wizard uses to call the service layer, keeping the
/// widget free of Riverpod imports.
class ForgotPasswordFlowApi {
  final Future<CloudSyncResult> Function(String email) sendOtp;
  final Future<CloudSyncResult> Function(String email, String code) verifyOtp;
  final Future<CloudSyncResult> Function(String newPassword) setPassword;

  const ForgotPasswordFlowApi({
    required this.sendOtp,
    required this.verifyOtp,
    required this.setPassword,
  });
}

/// Presents the full in-app 3-step OTP password recovery wizard:
///   1. Enter email → sends a 6-digit code.
///   2. Enter the code → verifies with Supabase.
///   3. Set a new password → updates via Supabase Auth.
///
/// Everything stays inside PYLO — no browser, no deep link, no localhost.
/// Pops with the final [CloudSyncResult] on completion or cancellation.
Future<CloudSyncResult?> showForgotPasswordFlow(
  BuildContext context,
  ForgotPasswordFlowApi api,
) {
  return showGlassBottomSheet<CloudSyncResult>(
    context,
    isScrollControlled: true,
    child: _ForgotPasswordFlow(api: api),
  );
}

enum _FlowStep { email, code, password }

class _ForgotPasswordFlow extends StatefulWidget {
  final ForgotPasswordFlowApi api;
  const _ForgotPasswordFlow({required this.api});

  @override
  State<_ForgotPasswordFlow> createState() => _ForgotPasswordFlowState();
}

class _ForgotPasswordFlowState extends State<_ForgotPasswordFlow> {
  static final _emailReg = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _newPwController = TextEditingController();
  final TextEditingController _confirmPwController = TextEditingController();

  _FlowStep _step = _FlowStep.email;
  bool _busy = false;
  String? _error;
  CloudSyncErrorKind _errorKind = CloudSyncErrorKind.unknown;

  int _cooldown = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _newPwController.dispose();
    _confirmPwController.dispose();
    super.dispose();
  }

  // ── Cooldown ──────────────────────────────────────────────────────────

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = 30);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _cooldown--;
        if (_cooldown <= 0) _cooldownTimer?.cancel();
      });
    });
  }

  // ── Step 1 — email ────────────────────────────────────────────────────

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (!_emailReg.hasMatch(email)) {
      setState(() {
        _error = 'Please enter a valid email address.';
        _errorKind = CloudSyncErrorKind.invalidEmail;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.api.sendOtp(email);
    if (!mounted) return;
    if (result.ok) {
      setState(() {
        _busy = false;
        _step = _FlowStep.code;
        _error = null;
      });
      _startCooldown();
    } else {
      setState(() {
        _busy = false;
        _error = result.message;
        _errorKind = result.error;
      });
    }
  }

  // ── Step 2 — code ─────────────────────────────────────────────────────

  Future<void> _verifyOtp() async {
    final code = _codeController.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    final result =
        await widget.api.verifyOtp(_emailController.text.trim(), code);
    if (!mounted) return;
    if (result.ok) {
      setState(() {
        _busy = false;
        _step = _FlowStep.password;
        _error = null;
      });
    } else {
      setState(() {
        _busy = false;
        _error = result.message;
        _errorKind = result.error;
      });
    }
  }

  Future<void> _resendOtp() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.api.sendOtp(_emailController.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      _startCooldown();
    } else {
      setState(() {
        _error = result.message;
        _errorKind = result.error;
      });
    }
  }

  // ── Step 3 — password ─────────────────────────────────────────────────

  String? _validatePw() {
    final pw = _newPwController.text.trim();
    final confirm = _confirmPwController.text.trim();
    if (pw.isEmpty) return 'Enter a new password.';
    if (pw.length < 6) {
      return 'New password must be at least 6 characters (the Supabase '
          'minimum).';
    }
    if (pw != confirm) return 'Passwords do not match.';
    return null;
  }

  Future<void> _setPassword() async {
    final problem = _validatePw();
    if (problem != null) {
      setState(() {
        _error = problem;
        _errorKind = CloudSyncErrorKind.unknown;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.api
        .setPassword(_newPwController.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      Navigator.pop(context, result);
    } else {
      setState(() {
        _error = result.message;
        _errorKind = result.error;
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isGlass = isGlassTheme(context);
    return DisposeOnExit(
      controllers: [
        _emailController,
        _codeController,
        _newPwController,
        _confirmPwController,
      ],
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
              Text('Reset Password',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isGlass ? GlassColors.textPrimary : null)),
              const SizedBox(height: 16),
              if (_step == _FlowStep.email) ...[
                Text(
                  'Enter the email address for your PYLO cloud account. We\'ll '
                  'send you a 6-digit code to verify it.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          isGlass ? GlassColors.textMuted : Colors.grey[600]),
                ),
                const SizedBox(height: 16),
                GlassInput(
                  controller: _emailController,
                  labelText: 'Email address',
                  keyboardType: TextInputType.emailAddress,
                ),
              ] else if (_step == _FlowStep.code) ...[
                Text(
                  'A 6-digit code was sent to ${_emailController.text.trim()}.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          isGlass ? GlassColors.textMuted : Colors.grey[600]),
                ),
                const SizedBox(height: 16),
                GlassInput(
                  controller: _codeController,
                  labelText: '6-digit code',
                  keyboardType: TextInputType.number,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    onPressed: (_cooldown > 0 || _busy)
                        ? null
                        : _resendOtp,
                    child: Text(
                      _cooldown > 0
                          ? 'Resend code in ${_cooldown}s'
                          : 'Resend code',
                    ),
                  ),
                ),
              ] else ...[
                Text(
                  'Verification passed. Choose a new password to finish.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          isGlass ? GlassColors.textMuted : Colors.grey[600]),
                ),
                const SizedBox(height: 16),
                GlassInput(
                  controller: _newPwController,
                  labelText: 'New password',
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                GlassInput(
                  controller: _confirmPwController,
                  labelText: 'Confirm new password',
                  obscureText: true,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  '${_kindLabel(_errorKind).$1}:\n$_error',
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                ),
              ],
              const SizedBox(height: 16),
              GlassButton(
                onPressed: _busy
                    ? null
                    : _step == _FlowStep.email
                        ? _sendOtp
                        : _step == _FlowStep.code
                            ? _verifyOtp
                            : _setPassword,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(
                        _step == _FlowStep.email
                            ? 'Send code'
                            : _step == _FlowStep.code
                                ? 'Verify code'
                                : 'Reset Password',
                      ),
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

(String, Color) _kindLabel(CloudSyncErrorKind kind) {
  switch (kind) {
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
    default:
      return ('Password reset', Colors.red);
  }
}