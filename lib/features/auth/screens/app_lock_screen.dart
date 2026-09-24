import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/focus_session_model.dart';
import '../../../navigation/app_navigation.dart';
import '../../../providers/focus_provider.dart';
import '../../../providers/security_provider.dart';
import '../../../services/security/biometric_service.dart';
import '../../../services/widget_action_handler.dart';
import '../../focus/screens/focus_active_screen.dart';
import '../widgets/pin_pad.dart';
import 'face_id_capture_screen.dart';

class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key});

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  String? _errorText;
  bool _authenticating = false;
  bool _widgetActionHandled = false;

  /// One-shot automatic biometric prompt. Set true the first time the app
  /// requires auth on a fresh launch so the native fingerprint dialog appears
  /// with no button tap — while resume-from-background relocks keep the
  /// existing manual policy (tap the fingerprint button).
  bool _autoBiometricPrompted = false;

  /// Drives the visible lockout countdown while it is active.
  Timer? _lockoutTicker;
  int _lockoutSecondsLeft = 0;

  static const int _maxPinAttempts = SecurityNotifier.maxPinAttempts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncLockout();
    });
  }

  void _syncLockout() {
    final notifier = ref.read(securityProvider.notifier);
    final seconds = notifier.pinLockoutSecondsLeft;
    if (seconds <= 0) {
      // Lockout expired (or never started): always tear the ticker down and
      // clear UI, even if the leftover flag says otherwise. This prevents a
      // frozen "18 s" countdown and a misleading "0 s" message.
      if (_lockoutSecondsLeft != 0 && mounted) {
        setState(() => _lockoutSecondsLeft = 0);
      }
      _lockoutTicker?.cancel();
      _lockoutTicker = null;
      if (_errorText != null && mounted) setState(() => _errorText = null);
      return;
    }
    if (seconds != _lockoutSecondsLeft) {
      setState(() => _lockoutSecondsLeft = seconds);
    }
    // Start the ticker on the FIRST locked-out sync too (not only on later
    // ones), otherwise a re-entered lockout never counts down.
    _lockoutTicker ??=
        Timer.periodic(const Duration(seconds: 1), (_) => _syncLockout());
  }

  String _lockoutLabel(int seconds) =>
      seconds > 0 ? '$seconds s' : 'a moment';

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockoutTicker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final security = ref.read(securityProvider.notifier);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        security.onAppPaused();
        break;
      case AppLifecycleState.resumed:
        security.onAppResumed();
        if (ref.read(securityProvider).requiresAuth) {
          setState(() => _errorText = null);
        }
      default:
        break;
    }
  }

  Future<void> _authenticateWithBiometric() async {
    if (_authenticating) return;
    final notifier = ref.read(securityProvider.notifier);
    // Biometrics are also blocked while the PIN lockout is active, otherwise
    // the throttle could be bypassed with a single fingerprint scan.
    if (notifier.isPinLockedOut) {
      _syncLockout();
      return;
    }
    _authenticating = true;
    final success =
        await BiometricService.authenticate(reason: 'Scan your fingerprint to unlock PYLO');
    _authenticating = false;
    if (!mounted) return;
    if (success) {
      ref.read(securityProvider.notifier).unlock();
      setState(() => _errorText = null);
    } else {
      setState(() => _errorText = 'Biometric failed. Enter PIN.');
    }
  }

  /// Dedicated on-device Face ID path — completely separate from the OS
  /// fingerprint scanner. Pushes the ML camera screen, which returns true
  /// only after a real embedding match passes the 0.85 threshold.
  Future<void> _authenticateWithFaceId() async {
    if (_authenticating) return;
    final notifier = ref.read(securityProvider.notifier);
    if (notifier.isPinLockedOut) {
      _syncLockout();
      return;
    }
    _authenticating = true;
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const FaceIdCaptureScreen(mode: FaceIdCaptureMode.authenticate),
      ),
    );
    _authenticating = false;
    if (!mounted) return;
    if (ok == true) {
      ref.read(securityProvider.notifier).unlock();
      setState(() => _errorText = null);
    } else {
      setState(() => _errorText = 'Face ID failed. Enter PIN.');
    }
  }

  Future<void> _onPinEntered(String pin) async {
    final notifier = ref.read(securityProvider.notifier);
    final valid = await notifier.verifyPinWithThrottle(pin);
    if (!mounted) return;
    if (valid) {
      notifier.unlock();
      setState(() => _errorText = null);
    } else if (notifier.isPinLockedOut) {
      setState(() => _errorText =
          'Too many attempts. Try again in ${_lockoutLabel(_lockoutSecondsLeft)}.');
      _syncLockout();
    } else {
      final left = _maxPinAttempts - notifier.pinFailedAttempts;
      setState(() => _errorText = 'Incorrect PIN'
          '${left > 0 && left <= 2 ? ' — $left attempt${left == 1 ? '' : 's'} left' : ''}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final security = ref.watch(securityProvider);

    if (security.isLoading) {
      return const Scaffold(
        // Black backdrop (not the theme's scaffold color): the persisted
        // theme has not loaded yet on this first frame, so a Dark/AMOLED/Glass
        // user must not see a white flash.
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FlutterLogo(size: 64),
              SizedBox(height: 24),
              CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }

    // Select `active` so the 1 s focus ticker does not rebuild the lock
    // screen; only session start/stop transitions matter here.
    final activeFocus = ref.watch(focusProvider.select((s) => s.active));

    // STRICT FOCUS: absolute priority. Skip app lock entirely.
    // The user is already "locked" in focus mode with its own PIN system.
    if (activeFocus != null && activeFocus.mode == FocusMode.strict) {
      return const FocusActiveScreen();
    }

    // NORMAL FOCUS: also show focus screen (can be exited with confirmation).
    if (activeFocus != null) {
      return const FocusActiveScreen();
    }

    // AUTO-FINGERPRINT ON LAUNCH: the instant the provider's Phase 2 check
    // confirms an enrolled, enabled biometric is available on a locked fresh
    // launch, prompt the native OS dialog immediately — no "Fingerprint"
    // button tap. One-shot per gate session (survives the session), so
    // background relocks keep the existing manual PIN/fingerprint policy and
    // there is never an auth loop. The existing `_authenticateWithBiometric`
    // guard also blocks the PIN lockout window and in-flight auth.
    if (!_autoBiometricPrompted && security.shouldOfferBiometric) {
      _autoBiometricPrompted = true;
      if (!ref.read(securityProvider.notifier).isPinLockedOut) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _authenticateWithBiometric();
        });
      }
    }

    if (!security.requiresAuth) {
      // Handle widget deep link action once when app becomes ready
      if (!_widgetActionHandled) {
        _widgetActionHandled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            WidgetActionHandler.handlePendingAction(context);
          }
        });
      }
      return const AppNavigation();
    }

    final lockedOut = _lockoutSecondsLeft > 0;
    String? errorText = _errorText;
    if (lockedOut) {
      errorText =
          'Too many attempts. Try again in ${_lockoutLabel(_lockoutSecondsLeft)}.';
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PinPad(
                title: 'PYLO is locked',
                errorText: errorText,
                onPinCompleted: _onPinEntered,
                showBiometric: security.shouldOfferBiometric && !lockedOut,
                onBiometricRequested: _authenticateWithBiometric,
                enabled: !lockedOut,
                onInputChanged: errorText == null
                    ? null
                    : () {
                        if (mounted && !lockedOut) {
                          setState(() => _errorText = null);
                        }
                      },
              ),
            ),
            if (security.shouldOfferFaceId && !lockedOut)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  onPressed: _authenticateWithFaceId,
                  icon: const Icon(Icons.face_outlined),
                  label: const Text('Unlock with Face ID'),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
