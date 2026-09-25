import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud/cloud_config_store.dart';
import '../services/cloud/cloud_sync_service.dart';
import 'database_provider.dart';

/// Read model for the WEB ACCESS section in Settings.
class CloudAuthState {
  final String? email;
  final bool busy;
  final bool testing;
  final bool notConfigured;

  const CloudAuthState({
    this.email,
    this.busy = false,
    this.testing = false,
    this.notConfigured = false,
  });

  bool get isConnected => email != null;

  CloudAuthState copyWith({
    String? email,
    bool clearEmail = false,
    bool? busy,
    bool? testing,
    bool? notConfigured,
  }) {
    return CloudAuthState(
      email: clearEmail ? null : email ?? this.email,
      busy: busy ?? this.busy,
      testing: testing ?? this.testing,
      notConfigured: notConfigured ?? this.notConfigured,
    );
  }
}

/// The user's chosen Supabase project (Settings → Web Access). Empty until the
/// user connects one on the Create Account screen. Loaded lazily via secure
/// storage, so a fresh install costs nothing at startup.
final cloudConfigStoreProvider = Provider<CloudConfigStore>((ref) {
  final store = CloudConfigStore();
  unawaited(store.load());
  return store;
});

/// Single app-wide [CloudSyncService] instance.
final cloudSyncServiceProvider = Provider<CloudSyncService>((ref) {
  final dbHelper = ref.watch(databaseProvider);
  final store = ref.watch(cloudConfigStoreProvider);
  final service = CloudSyncService(dbHelper, store);
  ref.onDispose(service.dispose);
  return service;
});

/// Auth state + user actions for the cloud account UI. Follows the project's
/// existing `StateNotifier<AsyncValue<T>>` convention (see taskProvider).
final cloudAuthProvider =
    StateNotifierProvider<CloudAuthNotifier, AsyncValue<CloudAuthState>>((ref) {
  final service = ref.watch(cloudSyncServiceProvider);
  return CloudAuthNotifier(service);
});

class CloudAuthNotifier extends StateNotifier<AsyncValue<CloudAuthState>> {
  final CloudSyncService service;
  bool _disposed = false;

  static final RegExp _emailReg = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  CloudAuthNotifier(this.service) : super(const AsyncValue.loading()) {
    service.authUser.addListener(_syncFromService);
    unawaited(restoreSession());
  }

  void _syncFromService() {
    if (_disposed) return;
    final current = state.maybeWhen(
      data: (value) => value,
      orElse: () => const CloudAuthState(),
    );
    state = AsyncValue.data(current.copyWith(
      email: service.currentEmail,
      clearEmail: service.currentEmail == null,
      notConfigured: !service.isConfigured,
    ));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    service.authUser.removeListener(_syncFromService);
    super.dispose();
  }

  /// Restores a persisted Supabase session (local, no network). Non-blocking
  /// and safe on every startup — if there is no session the app just stays in
  /// full offline mode. The service schedules the resume upload itself.
  Future<void> restoreSession() async {
    try {
      await service.restoreSession();
    } catch (_) {
    } finally {
      _syncFromService();
    }
  }

  Future<CloudSyncResult> createAccount(
    String email,
    String password,
    String confirmPassword, {
    CloudConfig? cloud,
  }) async {
    if (_disposed) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.notConfigured,
        'Cloud access is unavailable.',
      );
    }
    final current = state.maybeWhen(
      data: (value) => value,
      orElse: () => const CloudAuthState(),
    );
    if (current.busy || current.testing) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.unknown,
        'Wait for the current cloud action to finish.',
      );
    }
    if (password != confirmPassword) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.unknown,
        'Passwords do not match.',
      );
    }
    final normalizedEmail = email.trim().toLowerCase();
    if (!_emailReg.hasMatch(normalizedEmail)) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.invalidEmail,
        'Please enter a valid email address.',
      );
    }
    if (password.isEmpty || password.length < 6) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.weakPassword,
        'Password must be at least 6 characters (the Supabase minimum).',
      );
    }
    final normalizedCloud = cloud == null
        ? null
        : CloudConfig(url: cloud.url, anonKey: cloud.anonKey);
    if (normalizedCloud != null) {
      final configError = normalizedCloud.validationError;
      if (configError != null) {
        return CloudSyncResult.fail(
          CloudSyncErrorKind.invalidCredentials,
          configError,
        );
      }
    }
    if (normalizedCloud == null) {
      return const CloudSyncResult.ok(
        'Account created in offline mode — all data stays on this device. '
        'You can connect your own Supabase project later from this screen.',
      );
    }
    _setBusy(true);
    try {
      final result = await service.createAuthorizedAccount(
        url: normalizedCloud.url,
        anonKey: normalizedCloud.anonKey,
        email: normalizedEmail,
        password: password,
      );
      if (result.ok && service.isSignedIn) service.scheduleSync();
      return result;
    } finally {
      _setBusy(false);
      _syncFromService();
    }
  }

  /// Validates the entered Project URL + anon/public key against the user's own
  /// Supabase project without saving anything. Used by the Create Account
  /// sheet's "Test" button.
  Future<CloudSyncResult> testConnection(String url, String anonKey) async {
    if (_disposed) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.notConfigured,
        'Cloud access is unavailable.',
      );
    }
    final current = state.maybeWhen(
      data: (value) => value,
      orElse: () => const CloudAuthState(),
    );
    if (current.busy || current.testing) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.unknown,
        'Wait for the current cloud action to finish.',
      );
    }
    final candidate = CloudConfig(url: url, anonKey: anonKey);
    final configError = candidate.validationError;
    if (configError != null) {
      service.invalidateConnectionTest();
      return CloudSyncResult.fail(
        CloudSyncErrorKind.invalidCredentials,
        configError,
      );
    }
    _setTesting(true);
    try {
      return await service.testConnection(candidate.url, candidate.anonKey);
    } finally {
      _setTesting(false);
    }
  }

  void invalidateConnectionTest() {
    if (_disposed) return;
    service.invalidateConnectionTest();
  }

  bool get _actionBusy {
    if (_disposed) return true;
    final current = state.maybeWhen(
      data: (value) => value,
      orElse: () => const CloudAuthState(),
    );
    return current.busy || current.testing;
  }

  CloudSyncResult _actionInProgress() {
    return const CloudSyncResult.fail(
      CloudSyncErrorKind.unknown,
      'Wait for the current cloud action to finish.',
    );
  }

  Future<CloudSyncResult> login(String email, String password) async {
    if (_actionBusy) return _actionInProgress();
    _setBusy(true);
    try {
      final result = await service.login(email, password);
      if (result.ok && service.isSignedIn) service.scheduleSync();
      return result;
    } finally {
      _setBusy(false);
    }
  }

  Future<CloudSyncResult> forgotPassword(String email) async {
    if (_actionBusy) return _actionInProgress();
    _setBusy(true);
    try {
      return await service.requestRecoveryOtp(email);
    } finally {
      _setBusy(false);
    }
  }

  Future<CloudSyncResult> verifyRecoveryOtp(
    String email,
    String code,
  ) async {
    if (_actionBusy) return _actionInProgress();
    _setBusy(true);
    try {
      return await service.verifyRecoveryOtp(email, code);
    } finally {
      _setBusy(false);
    }
  }

  /// Completes the OTP recovery: sets the new password on the recovery
  /// session, then signs it out so the user logs in fresh.
  Future<CloudSyncResult> setPasswordAfterRecovery(String newPassword) async {
    if (_actionBusy) return _actionInProgress();
    _setBusy(true);
    try {
      return await service.setPasswordAfterRecovery(newPassword);
    } finally {
      _setBusy(false);
    }
  }

  Future<CloudSyncResult> logout() async {
    if (_actionBusy) return _actionInProgress();
    _setBusy(true);
    try {
      return await service.logout();
    } finally {
      _setBusy(false);
    }
  }

  Future<CloudSyncResult> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    if (_actionBusy) return _actionInProgress();
    _setBusy(true);
    try {
      return await service.changePassword(currentPassword, newPassword);
    } finally {
      _setBusy(false);
    }
  }

  Future<CloudSyncResult> changeEmail(
    String newEmail,
    String currentPassword,
  ) async {
    if (_actionBusy) return _actionInProgress();
    _setBusy(true);
    try {
      return await service.changeEmail(newEmail, currentPassword);
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    if (_disposed) return;
    final current = state.maybeWhen(
      data: (s) => s,
      orElse: () => const CloudAuthState(),
    );
    state = AsyncValue.data(current.copyWith(busy: value));
  }

  void _setTesting(bool value) {
    if (_disposed) return;
    final current = state.maybeWhen(
      data: (s) => s,
      orElse: () => const CloudAuthState(),
    );
    state = AsyncValue.data(current.copyWith(testing: value));
  }
}
