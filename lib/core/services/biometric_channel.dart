import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Outcome of a native system biometric prompt.
///
/// * [success] — the OS verified the user's biometric.
/// * [cancelled] — the user dismissed the prompt or pressed the negative
///   button ("Use PIN").
/// * [failed] — the prompt errored without a specific known cause (the user
///   should be offered PIN / retry).
/// * [notAvailable] — the OS has no enrolled/usable biometric.
/// * [lockout] — the OS temporarily/permanently locked out biometrics after
///   repeated failures (the user must use PIN for now).
/// * [error] — channel/implementation failure (fall back to PIN).
enum PyloBiometricOutcome { success, cancelled, failed, notAvailable, lockout, error }

/// MethodChannel bridge to the native Android `androidx.biometric`
/// BiometricPrompt.
///
/// Normal App Lock unlock runs EXCLUSIVELY through this platform prompt — no
/// custom camera UI, no CameraController, no hidden capture. The system itself
/// decides which enrolled modality (face, fingerprint, or iris) to use and
/// renders its own managed prompt.
///
/// Other platforms (iOS/desktop/web) keep using `local_auth`, which also
/// delegates to the OS system prompt — see [BiometricService].
class BiometricChannel {
  BiometricChannel._();

  static const MethodChannel _channel = MethodChannel('pylo/biometric');

  /// True when the platform currently has a usable enrolled biometric.
  /// Mirrors `BiometricManager.canAuthenticate`.
  static Future<bool> canAuthenticate() async {
    try {
      final result = await _channel.invokeMethod<bool>('canAuthenticate');
      return result ?? false;
    } catch (e) {
      debugPrint('Biometric canAuthenticate failed: $e');
      return false;
    }
  }

  /// Launches the system biometric prompt. Resolves exactly once when the
  /// prompt is dismissed, errors, or succeeds. On Android this maps the native
  /// status string onto [PyloBiometricOutcome].
  static Future<PyloBiometricOutcome> authenticate({
    String title = 'Unlock PYLO',
    String? subtitle,
    String negativeText = 'Use PIN',
  }) async {
    try {
      final status = await _channel.invokeMethod<String>('authenticate', {
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        'negativeText': negativeText,
      });
      return _mapStatus(status);
    } catch (e) {
      debugPrint('Biometric authenticate failed: $e');
      return PyloBiometricOutcome.error;
    }
  }

  /// Launches the OS enrollment screen so the user can add a face or
  /// fingerprint to the device itself (API 30+; older devices get the generic
  /// security settings screen). Resolves after the platform responds.
  static Future<bool> openEnrollmentSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openEnrollmentSettings') ??
          false;
    } catch (e) {
      debugPrint('openEnrollmentSettings failed: $e');
      return false;
    }
  }

  static PyloBiometricOutcome _mapStatus(String? status) {
    switch (status) {
      case 'success':
        return PyloBiometricOutcome.success;
      case 'cancelled':
        return PyloBiometricOutcome.cancelled;
      case 'busy':
      case 'failed':
        return PyloBiometricOutcome.failed;
      case 'notAvailable':
        return PyloBiometricOutcome.notAvailable;
      case 'lockout':
        return PyloBiometricOutcome.lockout;
      default:
        return PyloBiometricOutcome.error;
    }
  }
}