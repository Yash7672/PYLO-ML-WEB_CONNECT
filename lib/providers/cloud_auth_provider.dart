import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/cloud/cloud_sync_service.dart';
import 'database_provider.dart';

/// Read model for the WEB ACCESS section in Settings.
class CloudAuthState {
  final String? email;
  final bool busy;
  final bool notConfigured;

  const CloudAuthState({
    this.email,
    this.busy = false,
    this.notConfigured = false,
  });

  bool get isConnected => email != null;

  CloudAuthState copyWith({String? email, bool? busy, bool? notConfigured}) {
    return CloudAuthState(
      email: email ?? this.email,
      busy: busy ?? this.busy,
      notConfigured: notConfigured ?? this.notConfigured,
    );
  }
}

/// Single app-wide [CloudSyncService] instance.
final cloudSyncServiceProvider = Provider<CloudSyncService>((ref) {
  final dbHelper = ref.watch(databaseProvider);
  final service = CloudSyncService(dbHelper);
  ref.onDispose(service.dispose);
  return service;
});

/// Auth state + user actions for the cloud account UI. Follows the project's
/// existing `StateNotifier<AsyncValue<T>>` convention (see taskProvider).
final cloudAuthProvider =
    StateNotifierProvider<CloudAuthNotifier, AsyncValue<CloudAuthState>>(
        (ref) {
  final service = ref.watch(cloudSyncServiceProvider);
  return CloudAuthNotifier(service);
});

class CloudAuthNotifier extends StateNotifier<AsyncValue<CloudAuthState>> {
  final CloudSyncService service;

  CloudAuthNotifier(this.service) : super(const AsyncValue.loading()) {
    service.authUser.addListener(_syncFromService);
    unawaited(restoreSession());
  }

  void _syncFromService() {
    state = AsyncValue.data(CloudAuthState(
      email: service.currentEmail,
      notConfigured: !service.isConfigured,
    ));
  }

  @override
  void dispose() {
    service.authUser.removeListener(_syncFromService);
    super.dispose();
  }

  /// Restores a persisted Supabase session (local, no network). Non-blocking
  /// and safe on every startup — if there is no session the app just stays in
  /// full offline mode. The service schedules the resume upload itself.
  Future<void> restoreSession() async {
    await service.restoreSession();
    _syncFromService();
  }

  Future<CloudSyncResult> createAccount(
    String email,
    String password,
    String confirmPassword,
  ) async {
    if (password != confirmPassword) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.unknown,
        'Passwords do not match.',
      );
    }
    _setBusy(true);
    try {
      final result = await service.signUp(email, password);
      if (result.ok && service.isSignedIn) service.scheduleSync();
      return result;
    } finally {
      _setBusy(false);
    }
  }

  Future<CloudSyncResult> login(String email, String password) async {
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
    return service.setPasswordAfterRecovery(newPassword);
  }

  Future<CloudSyncResult> logout() async {
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
    _setBusy(true);
    try {
      return await service.changeEmail(newEmail, currentPassword);
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    final current = state.maybeWhen(
      data: (s) => s,
      orElse: () => const CloudAuthState(),
    );
    state = AsyncValue.data(current.copyWith(busy: value));
  }
}