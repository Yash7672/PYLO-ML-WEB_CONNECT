import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../database/database_helper.dart';
import '../../models/checklist_model.dart';
import '../../models/task_model.dart';
import 'net_probe_io.dart'
    if (dart.library.js) 'net_probe_web.dart' as net_probe;
import 'supabase_config.dart';
import 'today_data_serializer.dart';

/// Coarse outcome codes the Settings UI maps to friendly user messages,
/// keeping Supabase exception internals out of the UI layer.
enum CloudSyncErrorKind {
  none,
  network,
  server,
  invalidEmail,
  weakPassword,
  emailTaken,
  invalidCredentials,
  sessionExpired,
  notConfigured,
  unknown,
}

/// Result of every auth / sync user action. On success `message` may carry a
/// note (e.g. "verification email sent"); on failure it holds a friendly
/// human-readable explanation.
class CloudSyncResult {
  final bool ok;
  final CloudSyncErrorKind error;
  final String message;

  const CloudSyncResult.ok([this.message = ''])
      : ok = true,
        error = CloudSyncErrorKind.none;

  const CloudSyncResult.fail(this.error, [this.message = '']) : ok = false;
}

/// Optional Supabase-backed "today's data" sync for PYLO.
///
/// Design rules baked in:
///  - SQLite stays the source of truth; local-only fields are never rewritten.
///  - Uploads mirror today's snapshot to the cloud (debounced, hashed, lazy).
///  - Pulls (startup / resume / realtime / periodic) merge ONLY the remote
///    completion flags for rows that ALREADY exist locally; nothing is ever
///    created, deleted or reordered on the SQLite side by cloud data.
///  - The cloud stores ONE row per (user, local calendar date): today only.
///  - All network work is lazy, debounced and fire-and-forget from the UI.
///  - Offline / RLS-denied / server failures are swallowed: local data is
///    never rolled back and sync simply retries on the next change.
///  - A single in-flight guard + payload-hash dedupe skip no-op uploads.
///  - Uploads PULL FIRST (merge remote completions, then push) so a stale local
///    snapshot can never erase a remote change this device has not seen yet.
class CloudSyncService {
  CloudSyncService(this._dbHelper);

  final DatabaseHelper _dbHelper;

  Completer<void>? _initCompleter;
  bool _initialized = false;
  bool _initFailed = false;

  /// Latest authenticated Supabase user (null when signed out / not
  /// configured). Drives the Settings UI without re-reading gotrue internals.
  final ValueNotifier<User?> authUser = ValueNotifier<User?>(null);

  StreamSubscription<AuthState>? _authSub;

  Timer? _syncDebounce;
  bool _syncInFlight = false;
  String? _syncedDateKey;
  String? _syncedPayloadHash;

  Timer? _pullDebounce;
  Timer? _cloudRefreshTimer;
  bool _pullInFlight = false;
  String? _lastAppliedDateKey;

  /// Signature of the last remote row merged into SQLite: its `updated_at`
  /// PLUS every completion flag it carried. Deliberately not `updated_at`
  /// alone — a website write that changes the payload without bumping the
  /// timestamp must still be applied instead of being skipped as "seen".
  String? _lastAppliedSignature;

  /// Completion state this device last knows the CLOUD to hold — written by a
  /// pull and by every successful upload, keyed canonically (`task:<id>`,
  /// `<taskId>:<index>` for an embedded checklist item, or a standalone
  /// checklist item's own id). A LOCAL value that differs from its entry here is
  /// a change the cloud does not have yet, so it must win over — and never be
  /// overwritten by — an older remote copy. Null until the first exchange with
  /// the cloud this session.
  Map<String, bool>? _cloudCompletions;
  RealtimeChannel? _realtimeChannel;
  String? _realtimeForUserId;

  /// True while the realtime channel has reported a live subscription. While
  /// it is up the 30 s fallback poll is skipped (the channel is the fast
  /// path); _onRealtimeStatus clears it and restarts the poll the moment the
  /// channel closes, times out, or errors so syncing never silently stalls.
  bool _isRealtimeUp = false;

  /// Bumped whenever remote daily_data changes have been merged into SQLite.
  /// The app shell listens to this to reload providers and refresh the UI.
  final ValueNotifier<bool> remoteDataApplied = ValueNotifier<bool>(false);

  static const Duration _timeout = Duration(seconds: 20);

  /// Cadence of the background pull while signed in. Each tick is a single,
  /// small row fetch that SKIPS all work when the remote row's updated_at AND
  /// its completion flags are unchanged — the realtime listener (when the
  /// publication is enabled) is what delivers instant updates; this timer is
  /// the reliable fallback when realtime is unavailable or an event is missed.
  static const Duration _cloudRefreshInterval = Duration(seconds: 30);

  /// Upper bound for the error-path reachability probe. 6s per attempt is
  /// enough to tell "host unreachable" apart from a momentarily slow link.
  static const Duration _probeTimeout = Duration(seconds: 6);

  bool get isConfigured => SupabaseConfig.isConfigured;
  bool get isInitialized => _initialized;

  bool get isSignedIn {
    if (!_initialized) return false;
    return _client.auth.currentUser != null;
  }

  String? get currentUserId {
    if (!_initialized) return null;
    return _client.auth.currentUser?.id;
  }

  String? get currentEmail {
    if (!_initialized) return null;
    return _client.auth.currentUser?.email;
  }

  GoTrueClient get _auth => _client.auth;
  SupabaseClient get _client => Supabase.instance.client;

  /// Lazily initializes the single Supabase client. Idempotent, happens after
  /// the first frame, and can never throw: a missing publishable key or any
  /// platform init error simply leaves the app in full offline mode.
  Future<void> ensureInitialized() async {
    if (_initialized || _initFailed) return;
    final inFlight = _initCompleter;
    if (inFlight != null) {
      await inFlight.future;
      return;
    }
    if (!SupabaseConfig.isConfigured) {
      _initFailed = true;
      if (kDebugMode) {
        debugPrint('PYLO cloud config: ${SupabaseConfig.debugDescription()}');
      }
      return;
    }
    if (kDebugMode) {
      debugPrint('PYLO cloud config: ${SupabaseConfig.debugDescription()}');
    }
    final completer = Completer<void>();
    _initCompleter = completer;
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: SupabaseConfig.anonKey,
      );
      _initialized = true;
      _authSub?.cancel();
      _authSub = _auth.onAuthStateChange.listen(
        _onAuthStateChanged,
        onError: (Object e, StackTrace st) {
          if (kDebugMode) debugPrint('Cloud auth stream error: $e\n$st');
        },
      );
      authUser.value = _auth.currentUser;
      completer.complete();
    } catch (e, st) {
      _initFailed = true;
      if (kDebugMode) debugPrint('Supabase init failed: $e\n$st');
      completer.complete();
    } finally {
      _initCompleter = null;
    }
  }

  /// Restores any persisted session (local read, no network) so cloud sync
  /// resumes automatically without forcing a login. When a session exists,
  /// queues a debounced upload of today's snapshot, subscribes to the user's
  /// realtime channel and pulls any completion changes made from the website.
  Future<void> restoreSession() async {
    await ensureInitialized();
    authUser.value = _initialized ? _auth.currentUser : null;
    if (_initialized && isSignedIn) {
      final userId = currentUserId;
      if (userId != null) _subscribeRealtime(userId);
      _startCloudRefreshTimer();
      scheduleSync();
      schedulePull();
    }
  }

  /// Keeps the UI's auth state in lockstep with Supabase sessions
  /// (login, logout, token refresh, profile update). A fresh session also
  /// queues an immediate upload + pull; a lost session tears down the
  /// realtime listener and the background refresh timer.
  void _onAuthStateChanged(AuthState state) {
    // `AuthState.session` is a public field of another library, so it cannot be
    // type-promoted by a null check — hold it in a local instead.
    final session = state.session;
    authUser.value = session?.user;
    if (session != null) {
      _subscribeRealtime(session.user.id);
      _startCloudRefreshTimer();
      scheduleSync();
      schedulePull();
    } else {
      _unsubscribeRealtime();
      _stopCloudRefreshTimer();
      _lastAppliedDateKey = null;
      _lastAppliedSignature = null;
      _cloudCompletions = null;
    }
  }

  Future<bool> _prepare() async {
    if (!SupabaseConfig.isConfigured) return false;
    await ensureInitialized();
    return _initialized;
  }

  CloudSyncResult _notConfigured() => const CloudSyncResult.fail(
        CloudSyncErrorKind.notConfigured,
        'Cloud sync is not configured. Rebuild the app with the Supabase '
        'publishable key (--dart-define=SUPABASE_ANON_KEY=...).',
      );

  // ── Authentication ────────────────────────────────────────────────────

  Future<CloudSyncResult> signUp(String email, String password) async {
    if (!await _prepare()) return _notConfigured();
    final normalized = _normalizeEmail(email);
    final emailProblem = _validateEmail(normalized);
    if (emailProblem != null) {
      return CloudSyncResult.fail(
        CloudSyncErrorKind.invalidEmail,
        emailProblem,
      );
    }
    if (password.length < 6) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.weakPassword,
        'Password must be at least 6 characters.',
      );
    }
    try {
      final res = await _auth
          .signUp(email: normalized, password: password)
          .timeout(_timeout);
      if (res.session != null) {
        authUser.value = res.session?.user;
        scheduleSync();
        return const CloudSyncResult.ok();
      }
      // No session returned: email confirmation is enabled on the project.
      // The UI must not show "connected" (there is no session yet) and the
      // user just needs to verify their inbox.
      return const CloudSyncResult.ok(
        'Account created. Check your inbox to confirm your email address '
        'before logging in.',
      );
    } catch (e) {
      return _classify(e);
    }
  }

  Future<CloudSyncResult> login(String email, String password) async {
    if (!await _prepare()) return _notConfigured();
    final normalized = _normalizeEmail(email);
    final emailProblem = _validateEmail(normalized);
    if (emailProblem != null) {
      return CloudSyncResult.fail(
        CloudSyncErrorKind.invalidEmail,
        emailProblem,
      );
    }
    if (password.isEmpty) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.invalidCredentials,
        'Enter your password.',
      );
    }
    try {
      final res = await _auth
          .signInWithPassword(email: normalized, password: password)
          .timeout(_timeout);
      authUser.value = res.user;
      scheduleSync();
      return const CloudSyncResult.ok();
    } catch (e) {
      return _classify(e);
    }
  }

  /// Sends Supabase's email-OTP recovery code (`signInWithOtp` with
  /// `shouldCreateUser: false`) — a 6-digit code emailed to the user, no link,
  /// no browser, no redirect URL. `shouldCreateUser: false` means unknown
  /// addresses silently no-op (Supabase's anti-enumeration), so nothing leaks
  /// whether an account exists.
  Future<CloudSyncResult> requestRecoveryOtp(String email) async {
    if (!await _prepare()) return _notConfigured();
    final normalized = _normalizeEmail(email);
    final emailProblem = _validateEmail(normalized);
    if (emailProblem != null) {
      return CloudSyncResult.fail(
        CloudSyncErrorKind.invalidEmail,
        emailProblem,
      );
    }
    try {
      await _auth
          .signInWithOtp(email: normalized, shouldCreateUser: false)
          .timeout(_timeout);
      return const CloudSyncResult.ok(
        'We\'ve sent a 6-digit code to your email.',
      );
    } catch (e) {
      if (e is AuthException && (e.statusCode != null || e.code != null)) {
        final text = e.message.toLowerCase();
        final code = (e.code ?? '').toLowerCase();
        if (code.contains('over_request_rate_limit') ||
            text.contains('rate limit') ||
            text.contains('too many requests')) {
          return const CloudSyncResult.fail(
            CloudSyncErrorKind.server,
            'Too many requests. Please wait a moment before asking for '
            'another code.',
          );
        }
        final mapped = _mapServerAuthError(e);
        if (mapped != null) return mapped;
        return CloudSyncResult.fail(
          CloudSyncErrorKind.server,
          'Could not send the code'
          '${e.statusCode != null ? ' (HTTP ${e.statusCode})' : ''}. '
          'Please try again.',
        );
      }
      return _classify(e);
    }
  }

  /// Verifies the emailed 6-digit code with Supabase
  /// (`verifyOTP(type: OtpType.recovery)`), establishing the recovery session
  /// that lets [setPasswordAfterRecovery] run without the current password.
  /// The code only lives in memory during this flow; it is never persisted or
  /// logged.
  Future<CloudSyncResult> verifyRecoveryOtp(
    String email,
    String code,
  ) async {
    if (!await _prepare()) return _notConfigured();
    final normalized = _normalizeEmail(email);
    final trimmed = code.trim();
    if (trimmed.length != 6 || int.tryParse(trimmed) == null) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.invalidCredentials,
        'Enter the full 6-digit code from the email.',
      );
    }
    try {
      final res = await _auth
          .verifyOTP(
            email: normalized,
            token: trimmed,
            type: OtpType.recovery,
          )
          .timeout(_timeout);
      authUser.value = res.user;
      return const CloudSyncResult.ok();
    } catch (e) {
      if (e is AuthException && (e.statusCode != null || e.code != null)) {
        final text = e.message.toLowerCase();
        final code = (e.code ?? '').toLowerCase();
        if (code.contains('otp_expired') || text.contains('expired')) {
          return const CloudSyncResult.fail(
            CloudSyncErrorKind.invalidCredentials,
            'This code has expired. Request a new one.',
          );
        }
        if (code.contains('token_not_found') ||
            text.contains('invalid') ||
            text.contains('incorrect') ||
            text.contains('not found')) {
          return const CloudSyncResult.fail(
            CloudSyncErrorKind.invalidCredentials,
            'That code is incorrect. Please check the email and try again.',
          );
        }
        final mapped = _mapServerAuthError(e);
        if (mapped != null) return mapped;
        return CloudSyncResult.fail(
          CloudSyncErrorKind.server,
          'Could not verify the code'
          '${e.statusCode != null ? ' (HTTP ${e.statusCode})' : ''}. '
          'Please try again.',
        );
      }
      return _classify(e);
    }
  }

  /// Finishes the in-app password recovery. The recovery session established by
  /// `verifyOTP(type: recovery)` lets `updateUser(password:)` run without the
  /// current password. The recovery session is signed out on success so the
  /// user logs in fresh with the new password (never stuck in a recovery
  /// session).
  Future<CloudSyncResult> setPasswordAfterRecovery(String newPassword) async {
    if (!await _prepare()) return _notConfigured();
    if (newPassword.length < 6) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.weakPassword,
        'New password must be at least 6 characters.',
      );
    }
    try {
      final updated = await _auth
          .updateUser(UserAttributes(password: newPassword))
          .timeout(_timeout);
      authUser.value = updated.user;
      await _auth.signOut().timeout(_timeout);
      authUser.value = null;
      _resetSyncState();
      return const CloudSyncResult.ok(
        'Password reset successfully. Log in with your new password.',
      );
    } catch (e) {
      return _classify(e);
    }
  }

  Future<CloudSyncResult> logout({bool deleteCloudCopy = true}) async {
    if (!await _prepare()) return _notConfigured();
    try {
      if (deleteCloudCopy) await _deleteTodayQuietly();
      await _auth.signOut().timeout(_timeout);
      authUser.value = null;
      _resetSyncState();
      return const CloudSyncResult.ok();
    } catch (e) {
      return _classify(e);
    }
  }

  /// Changes the Supabase password. A fresh password sign-in guarantees a
  /// recent session, so `updateUser(password:)` is accepted even when
  /// "Reauthentication required" is enabled in the Supabase project.
  Future<CloudSyncResult> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    if (!await _prepare()) return _notConfigured();
    final email = _auth.currentUser?.email;
    if (email == null) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.sessionExpired,
        'Your session expired. Please log in again.',
      );
    }
    if (newPassword.length < 6) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.weakPassword,
        'New password must be at least 6 characters.',
      );
    }
    try {
      final res = await _auth
          .signInWithPassword(email: email, password: currentPassword)
          .timeout(_timeout);
      authUser.value = res.user;
      final updated = await _auth
          .updateUser(UserAttributes(password: newPassword))
          .timeout(_timeout);
      authUser.value = updated.user;
      return const CloudSyncResult.ok('Password updated.');
    } catch (e) {
      return _classify(e);
    }
  }

  /// Changes the Gmail/email using Supabase Auth's proper mechanism. Local
  /// SQLite data is untouched. If the project requires email confirmation the
  /// change only applies after the user follows the verification link.
  Future<CloudSyncResult> changeEmail(
    String newEmail,
    String currentPassword,
  ) async {
    if (!await _prepare()) return _notConfigured();
    final current = _auth.currentUser?.email;
    if (current == null) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.sessionExpired,
        'Your session expired. Please log in again.',
      );
    }
    final normalized = _normalizeEmail(newEmail);
    final emailProblem = _validateEmail(normalized);
    if (emailProblem != null) {
      return CloudSyncResult.fail(
        CloudSyncErrorKind.invalidEmail,
        emailProblem,
      );
    }
    if (normalized == current.toLowerCase()) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.invalidEmail,
        'That is already your current email.',
      );
    }
    try {
      final res = await _auth
          .signInWithPassword(email: current, password: currentPassword)
          .timeout(_timeout);
      authUser.value = res.user;
      final updated = await _auth
          .updateUser(UserAttributes(email: normalized))
          .timeout(_timeout);
      authUser.value = updated.user;
      if (updated.user?.newEmail != null) {
        return CloudSyncResult.ok(
          'A verification link was sent to $normalized. Your email changes '
          'after you confirm it.',
        );
      }
      return const CloudSyncResult.ok('Email updated.');
    } catch (e) {
      return _classify(e);
    }
  }

  // ── Cloud sync ────────────────────────────────────────────────────────

  /// Queues a debounced upload of today's snapshot. Called after every local
  /// mutation (and on login) so bursts of edits coalesce into one request.
  void scheduleSync() {
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(seconds: 3), () {
      unawaited(syncNow());
    });
  }

  /// Upserts today's local snapshot into `daily_data` for the signed-in user.
  /// Offline-first: never throws, never touches SQLite, never blocks callers.
  /// Concurrent calls coalesce; unchanged payloads skip the network entirely.
  Future<void> syncNow() async {
    if (_syncInFlight) return;
    if (!_initialized || !isSignedIn) return;
    _syncInFlight = true;
    try {
      final now = DateTime.now();
      final dateKey = localDateKey(now);

      // ── Pull-then-push (never clobber an unseen remote change) ─────────
      // Merge any remote completion change BEFORE overwriting the row with our
      // snapshot. Without this, a debounced upload queued by a local edit (or
      // by startup/resume) could erase a website tick this device had not
      // pulled yet — after which every client would agree on the stale value.
      // The merge never touches a completion the user changed here after the
      // last push (see [_cloudCompletions]), so it cannot revert our own tick,
      // and it is a no-op when the remote row is unchanged.
      final pulled = await _mergeRemoteRow();
      if (pulled > 0) _notifyRemoteApplied();

      final data = await buildTodayCloudData(_dbHelper, now);
      final payloadHash = _hashPayload(dateKey, data);
      if (dateKey == _syncedDateKey && payloadHash == _syncedPayloadHash) {
        return; // unchanged since the last successful upload for today.
      }

      final userId = currentUserId;
      if (userId == null) return;

      await _client
          .from('daily_data')
          .upsert(
            {
              // The row's PK has no server default, so it must be provided.
              // A UUIDv5 of (user, date) keeps it identical across upserts.
              'id': _rowId(userId, dateKey),
              'user_id': userId,
              'data_date': dateKey,
              'tasks': data.tasks,
              'lists': data.lists,
              'sublists': data.sublists,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            },
            onConflict: 'user_id,data_date',
          )
          .timeout(_timeout);

      _syncedDateKey = dateKey;
      _syncedPayloadHash = payloadHash;
      // The cloud now holds exactly these completion states.
      _cloudCompletions = _completionMapOf(data);
      if (kDebugMode) {
        debugPrint('[PYLO SYNC] Uploaded today\'s snapshot ($dateKey)');
      }
    } catch (e) {
      // Offline, RLS denied or server hiccup: keep the local change, retry on
      // the next mutation. Only a successful upload marks the payload synced.
      if (kDebugMode) debugPrint('Cloud sync skipped (will retry): $e');
    } finally {
      _syncInFlight = false;
    }
  }

  /// Reads today's cloud row ({tasks, lists, sublists, updated_at, data_date})
  /// or null when the signed-in user has none. Used by [_mergeRemoteRow] as the
  /// source for the remote completion-state merge.
  ///
  /// "Today" is the DEVICE's local calendar day (IST for this project), which
  /// is what [localDateKey] writes on upload — deliberately never the UTC date,
  /// so a user in India is not pushed onto yesterday's/tomorrow's row. The one
  /// fallback covers the mirror case: India is UTC+5:30, so between 00:00 and
  /// 05:29 IST the UTC date is still yesterday, and a writer that dates rows in
  /// UTC has its "today" under that key. That row is accepted ONLY as a fallback
  /// (never preferred over the local-date row) and only when it really is within
  /// a day of today — an arbitrary older row is never merged into today.
  Future<Map<String, dynamic>?> fetchToday() async {
    if (!_initialized || !isSignedIn) return null;
    final userId = currentUserId;
    if (userId == null) return null;
    final now = DateTime.now();
    final localKey = localDateKey(now);
    final utcKey = localDateKey(now.toUtc());
    try {
      final localRow = await _selectRowForDate(userId, localKey);
      if (localRow != null) return localRow;

      if (utcKey != localKey) {
        final utcRow = await _selectRowForDate(userId, utcKey);
        if (utcRow != null && _isNearToday(utcRow['data_date'], now)) {
          if (kDebugMode) {
            debugPrint('[PYLO SYNC] No row dated $localKey; using the '
                'UTC-dated row $utcKey');
          }
          return utcRow;
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('Cloud fetch failed (offline?): $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _selectRowForDate(
    String userId,
    String dateKey,
  ) async {
    return await _client
        .from('daily_data')
        .select('data_date,tasks,lists,sublists,updated_at')
        .eq('user_id', userId)
        .eq('data_date', dateKey)
        .maybeSingle()
        .timeout(_timeout);
  }

  /// True when the remote `data_date` is today, yesterday or tomorrow in local
  /// time — the drift a UTC-vs-local date difference can produce. Anything
  /// further away is a different day.
  static bool _isNearToday(Object? remoteDate, DateTime now) {
    if (remoteDate is! String) return false;
    final parsed = DateTime.tryParse(remoteDate);
    if (parsed == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    final remote = DateTime(parsed.year, parsed.month, parsed.day);
    final diff = remote.difference(today).inDays;
    return diff >= -1 && diff <= 1;
  }

  /// Deletes today's cloud copy for the signed-in user (e.g. on logout).
  Future<void> deleteToday() => _deleteTodayQuietly();

  // ── Remote pull (WEB → SUPABASE → FLUTTER) ─────────────────────────────

  /// Debounced pull. Called from realtime events, app resume/startup and the
  /// periodic refresh timer; bursts coalesce into one fetch-apply cycle.
  void schedulePull() {
    _pullDebounce?.cancel();
    _pullDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(syncFromCloud());
    });
  }

  /// Pulls today's remote row and merges any completion-state change made on
  /// the PYLO website into SQLite, then tells the app shell to reload the
  /// providers so the visible UI updates. Offline-first: never throws, never
  /// blocks callers, never creates/deletes rows — only completion flags are
  /// touched, and only for rows that already exist locally.
  Future<void> syncFromCloud() async {
    if (_pullInFlight) return;
    if (!_initialized || !isSignedIn) return;
    _pullInFlight = true;
    try {
      final applied = await _mergeRemoteRow();
      if (applied > 0) _notifyRemoteApplied();
    } catch (e) {
      if (kDebugMode) debugPrint('Cloud pull skipped (will retry): $e');
    } finally {
      _pullInFlight = false;
    }
  }

  /// Fetches today's remote row and merges its completion state into SQLite.
  /// Shared by the pull (realtime / resume / startup / periodic) AND by the
  /// upload path, so an upload can never overwrite a remote change this device
  /// has not applied yet. Returns how many local rows changed; skips all DB
  /// work when the remote row is byte-for-byte the one already merged.
  Future<int> _mergeRemoteRow() async {
    final row = await fetchToday();
    if (row == null) {
      if (kDebugMode) debugPrint('[PYLO SYNC] No daily_data row for today');
      return 0;
    }

    final remoteDate =
        row['data_date'] is String ? row['data_date'] as String : null;
    final signature = _remoteSignature(row);
    if (remoteDate == _lastAppliedDateKey &&
        signature == _lastAppliedSignature) {
      return 0; // same row + same completion state we already merged.
    }

    if (kDebugMode) {
      debugPrint(
        '[PYLO SYNC] Remote data parsed (data_date=$remoteDate, '
        'tasks=${_asMaps(row['tasks']).length}, '
        'lists=${_asMaps(row['lists']).length}, '
        'sublists=${_asMaps(row['sublists']).length})',
      );
    }

    // Completion states the user changed here since the last push must survive
    // this (necessarily older) remote copy.
    final keepLocal = await _pendingLocalIds();

    final applied = await _applyRemoteCompletionState(
      row,
      keepLocalIds: keepLocal,
    );
    _rememberCloudCompletions(row);

    // Remember what we applied even when nothing changed so the periodic
    // timer doesn't refetch/re-mix the same row on every tick.
    _lastAppliedDateKey = remoteDate;
    _lastAppliedSignature = signature;

    if (kDebugMode) {
      debugPrint('[PYLO SYNC] Remote data written to SQLite '
          '($applied change(s), ${keepLocal.length} local change(s) kept)');
    }
    return applied;
  }

  /// Tells the app shell that SQLite changed because of remote data, so it
  /// reloads the task/checklist providers and the visible UI refreshes.
  void _notifyRemoteApplied() {
    remoteDataApplied.value = !remoteDataApplied.value;
    if (kDebugMode) debugPrint('[PYLO SYNC] Flutter state refreshed');
  }

  /// Completion flags of everything we hold for TODAY, keyed exactly like the
  /// cloud payload (`task:<id>`, `<taskId>:<index>`, standalone item id) so the
  /// local state can be diffed against the last known cloud state.
  Future<Map<String, bool>> _localCompletionMap() async {
    final now = DateTime.now();
    final map = <String, bool>{};
    for (final task in await _dbHelper.getTasksByDate(now)) {
      map['task:${task.id}'] = task.isCompleted;
      for (var i = 0; i < task.checklist.length; i++) {
        map['${task.id}:$i'] = task.checklist[i].done;
      }
    }
    final items = await _dbHelper.getAllChecklistItems();
    for (final list in items.values) {
      for (final item in list) {
        map[item.id] = item.completed;
      }
    }
    return map;
  }

  /// Ids whose LOCAL completion state differs from the last completion state
  /// this device knows the cloud to hold — i.e. changes made here that have not
  /// been pushed yet. They must win over the remote copy, otherwise the sync
  /// would erase the user's own tick. Empty until the first exchange with the
  /// cloud this session, which keeps the long-standing behaviour of letting the
  /// cloud win for anything that differs right after a fresh start.
  Future<Set<String>> _pendingLocalIds() async {
    final cloud = _cloudCompletions;
    if (cloud == null) return const <String>{};
    final local = await _localCompletionMap();
    final pending = <String>{};
    local.forEach((id, value) {
      if (cloud[id] != value) pending.add(id);
    });
    return pending;
  }

  /// Records the completion state the cloud now holds — from a pulled row — so
  /// the next upload can tell which local changes the cloud does not have yet.
  void _rememberCloudCompletions(Map<String, dynamic> row) {
    final map = _cloudCompletions ?? <String, bool>{};
    for (final entry in _asMaps(row['tasks'])) {
      final id = entry['id'];
      if (id is! String) continue;
      final done = _readRemoteCompleted(entry);
      if (done != null) map['task:$id'] = done;
      final checklist = _asMaps(entry['checklist']);
      for (var i = 0; i < checklist.length; i++) {
        final itemDone = _readRemoteCompleted(checklist[i]);
        if (itemDone != null) map['$id:$i'] = itemDone;
      }
    }
    for (final entry in _asMaps(row['sublists'])) {
      final id = entry['id'];
      if (id is! String) continue;
      final done = _readRemoteCompleted(entry);
      if (done != null) map[id] = done;
    }
    for (final list in _asMaps(row['lists'])) {
      for (final key in const ['items', 'sublists', 'checklist']) {
        for (final item in _asMaps(list[key])) {
          final id = item['id'];
          if (id is! String) continue;
          final done = _readRemoteCompleted(item);
          if (done != null) map[id] = done;
        }
      }
    }
    _cloudCompletions = map;
  }

  /// Completion flags contained in a built cloud snapshot, keyed the same way as
  /// [_localCompletionMap] so the two can be diffed after an upload.
  static Map<String, bool> _completionMapOf(DailyCloudData data) {
    final map = <String, bool>{};
    for (final task in data.tasks) {
      final id = task['id'];
      if (id is! String) continue;
      map['task:$id'] = task['isCompleted'] == true;
      final checklist = task['checklist'];
      if (checklist is List) {
        for (var i = 0; i < checklist.length; i++) {
          final item = checklist[i];
          if (item is Map) map['$id:$i'] = item['done'] == true;
        }
      }
    }
    for (final item in data.sublists) {
      final id = item['id'];
      if (id is! String || item['source'] != 'checklist') continue;
      map[id] = item['completed'] == true;
    }
    return map;
  }

  /// Merges ONLY completion flags from the remote today's payload into SQLite,
  /// matching existing rows by id. Rows that exist only locally or only in the
  /// cloud are left untouched: SQLite remains the local source of truth and
  /// historical data is never deleted, added or rewritten beyond completion.
  ///
  /// The payload is read TOLERANTLY, because a tick made on the website can
  /// reach us in more than one shape and must never be silently dropped:
  ///   • `sublists[]`   (canonical): flat rows carrying `id` + `completed`,
  ///   • `tasks[].checklist[]`: the checklist embedded in a task (`done`),
  ///   • `lists[].items[]` / `.sublists[]` / `.checklist[]`: items nested
  ///     inside their parent list.
  /// Item ids are resolved from the row itself (exact checklist-item id, or
  /// `<taskId>:<index>` for an embedded item) — never from the optional
  /// `source` hint — so a writer that omits or renames `source` still lands.
  ///
  /// Ids in [keepLocalIds] are completion states the user changed HERE after the
  /// last push: the cloud copy is necessarily older, so those values are left
  /// untouched (and the next upload sends them on).
  /// Returns how many local rows actually changed.
  Future<int> _applyRemoteCompletionState(
    Map<String, dynamic> row, {
    Set<String> keepLocalIds = const <String>{},
  }) async {
    final now = DateTime.now();
    final localTasks = await _dbHelper.getTasksByDate(now);
    final localTaskById = <String, Task>{for (final t in localTasks) t.id: t};

    // Every completion flag the payload carries, with ALL copies of one item
    // kept: a writer can echo the same item twice (flat `sublists[]` next to the
    // task's embedded `checklist[]`) and one of those copies may be a stale echo.
    //   taskFlags: task id -> the values of `isCompleted`
    //   itemFlags: '<taskId>:<index>' (embedded) or the item's own id -> values
    final taskFlags = <String, List<bool>>{};
    final itemFlags = <String, List<bool>>{};
    void addFlag(Map<String, List<bool>> target, Object? id, bool? value) {
      if (id is! String || id.isEmpty || value == null) return;
      target.putIfAbsent(id, () => <bool>[]).add(value);
    }

    for (final entry in _asMaps(row['tasks'])) {
      final taskId = entry['id'];
      if (taskId is! String) continue;
      addFlag(taskFlags, taskId, _readRemoteCompleted(entry));
      final checklist = _asMaps(entry['checklist']);
      for (var i = 0; i < checklist.length; i++) {
        addFlag(itemFlags, '$taskId:$i', _readRemoteCompleted(checklist[i]));
      }
    }
    for (final entry in _asMaps(row['sublists'])) {
      addFlag(itemFlags, entry['id'], _readRemoteCompleted(entry));
    }
    for (final list in _asMaps(row['lists'])) {
      for (final key in const ['items', 'sublists', 'checklist']) {
        for (final item in _asMaps(list[key])) {
          addFlag(itemFlags, item['id'], _readRemoteCompleted(item));
        }
      }
    }
    if (taskFlags.isEmpty && itemFlags.isEmpty) return 0;

    var changed = 0;
    final consumed = <String>{};
    var matchedIds = 0;
    var unknownIds = 0;

    // ── 1. Items embedded in today's tasks ('<taskId>:<index>') ──────────
    final checklistPlan = <String, Map<int, bool>>{};
    for (final entry in itemFlags.entries) {
      final key = entry.key;
      if (keepLocalIds.contains(key)) continue;
      final sep = key.lastIndexOf(':');
      if (sep <= 0) continue;
      final task = localTaskById[key.substring(0, sep)];
      final index = int.tryParse(key.substring(sep + 1));
      if (task == null ||
          index == null ||
          index < 0 ||
          index >= task.checklist.length) {
        unknownIds++;
        continue; // not an embedded item of a task we hold today.
      }
      matchedIds++;
      consumed.add(key);
      final resolved =
          _resolveRemoteCompletion(entry.value, task.checklist[index].done);
      if (resolved == null) continue;
      checklistPlan.putIfAbsent(task.id, () => <int, bool>{})[index] = resolved;
    }

    // ── 2. Task rows: flag + embedded checklist in ONE write per task ────
    for (final task in localTasks) {
      final flags = taskFlags[task.id];
      final plan = checklistPlan[task.id];

      bool? remoteCompleted;
      if (flags != null && !keepLocalIds.contains('task:${task.id}')) {
        remoteCompleted = _resolveRemoteCompletion(flags, task.isCompleted);
      }

      var checklist = task.checklist;
      if (plan != null && plan.isNotEmpty) {
        final updated = List<ChecklistItemData>.of(checklist);
        var touched = false;
        plan.forEach((index, done) {
          if (updated[index].done == done) return;
          updated[index] = updated[index].copyWith(done: done);
          touched = true;
        });
        if (touched) checklist = updated;
      }

      if (remoteCompleted == null && identical(checklist, task.checklist)) {
        continue;
      }

      // Same mapping as before: the payload's own `completedAt` (epoch ms) when
      // it carries one, cleared when the task is un-completed.
      final completedAtMs = _completedAtOf(row, task.id);

      await _dbHelper.updateTask(task.copyWith(
        isCompleted: remoteCompleted ?? task.isCompleted,
        completedAt: remoteCompleted == null
            ? task.completedAt
            : (completedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(completedAtMs)),
        checklist: checklist,
        updatedAt: now,
      ));
      changed++;
    }

    // ── 3. Standalone quick-checklist items (id = the item's own id) ─────
    final localItemById = <String, ChecklistItem>{};
    var itemsLoaded = false;
    for (final entry in itemFlags.entries) {
      if (consumed.contains(entry.key) || keepLocalIds.contains(entry.key)) {
        continue;
      }
      if (!itemsLoaded) {
        itemsLoaded = true;
        final itemMap = await _dbHelper.getAllChecklistItems();
        for (final items in itemMap.values) {
          for (final item in items) {
            localItemById[item.id] = item;
          }
        }
      }
      final local = localItemById[entry.key];
      if (local == null) {
        unknownIds++;
        continue;
      }
      matchedIds++;
      final resolved =
          _resolveRemoteCompletion(entry.value, local.completed);
      if (resolved == null) continue;
      await _dbHelper.updateChecklistItem(
        local.copyWith(completed: resolved),
      );
      changed++;
    }

    if (kDebugMode) {
      debugPrint('[PYLO SYNC] Remote completion ids: $matchedIds matched '
          'locally, $unknownIds unknown');
    }
    return changed;
  }

  /// `completedAt` (epoch ms) the payload carries for a task, or null.
  static int? _completedAtOf(Map<String, dynamic> row, String taskId) {
    for (final entry in _asMaps(row['tasks'])) {
      if (entry['id'] != taskId) continue;
      final value = entry['completedAt'];
      if (value is num) return value.toInt();
      return null;
    }
    return null;
  }

  /// Picks the value to apply for one item from every copy the payload carried.
  /// The copy that DIFFERS from the local value is the one that changed; a copy
  /// equal to the local value is a stale echo of the pre-change state. Returns
  /// null when nothing would change.
  static bool? _resolveRemoteCompletion(List<bool> values, bool local) {
    for (final value in values) {
      if (value != local) return value;
    }
    return null;
  }

  /// Reads a completion flag from a cloud row, tolerating the name the writer
  /// used: the same state travels as `completed` (flat sublists), `isCompleted`
  /// (tasks) and `done` (a task's embedded checklist). Returns null when the
  /// payload carries no recognizable flag, so an unknown shape is never
  /// mistaken for "not completed".
  static bool? _readRemoteCompleted(Map<dynamic, dynamic> entry) {
    for (final key in const ['completed', 'isCompleted', 'done', 'isDone']) {
      final value = entry[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
    }
    return null;
  }

  /// Narrows a decoded JSON value to a list of maps, ignoring anything else so
  /// a malformed payload can never throw here.
  static List<Map<dynamic, dynamic>> _asMaps(Object? value) {
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is Map) entry,
    ];
  }

  /// Signature of everything the merge cares about: the row's `updated_at` plus
  /// every completion flag it carries. Lets the pull skip the SQLite work (and
  /// the provider reload) when it would be a no-op — and, unlike `updated_at`
  /// alone, still detects a payload change whose timestamp did not move.
  static String _remoteSignature(Map<String, dynamic> row) {
    final buffer = StringBuffer(row['updated_at']?.toString() ?? '');

    void addFlag(Object? id, bool? completed) {
      if (id == null) return;
      buffer.write('|$id:${completed == null ? '?' : (completed ? 1 : 0)}');
    }

    for (final entry in _asMaps(row['tasks'])) {
      addFlag('task:${entry['id']}', _readRemoteCompleted(entry));
      final checklist = _asMaps(entry['checklist']);
      for (var i = 0; i < checklist.length; i++) {
        addFlag('${entry['id']}:$i', _readRemoteCompleted(checklist[i]));
      }
    }
    for (final entry in _asMaps(row['sublists'])) {
      addFlag(entry['id'], _readRemoteCompleted(entry));
    }
    for (final list in _asMaps(row['lists'])) {
      for (final key in const ['items', 'sublists', 'checklist']) {
        for (final item in _asMaps(list[key])) {
          addFlag(item['id'], _readRemoteCompleted(item));
        }
      }
    }
    return buffer.toString();
  }

  // ── Realtime listener (best-effort; polling is the fallback) ───────────

  /// Listens for UPDATEs on the signed-in user's OWN `daily_data` row only,
  /// so a website completion change lands instantly. Limited by the `user_id`
  /// filter to the authenticated user — no other user's rows are ever received
  /// or processed, and the user id comes from the session, never from a
  /// payload. Requires the table to be in the realtime publication; when it is
  /// not, the periodic timer and the resume/startup pulls still deliver the
  /// change. Only one channel per signed-in session exists (re-subscribing for
  /// the same user is a no-op; logout disposes it).
  void _subscribeRealtime(String userId) {
    if (_realtimeForUserId == userId && _realtimeChannel != null) return;
    _realtimeForUserId = userId;
    _unsubscribeRealtime();
    try {
      _realtimeChannel = _client
          .channel('pylo-daily-sync-$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'daily_data',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (_) {
              // The event payload is deliberately NOT trusted as the source of
              // truth: what a subscriber receives depends on its RLS/column
              // access, so the row is re-read with THIS session's token by the
              // debounced pull below.
              if (kDebugMode) {
                debugPrint('[PYLO SYNC] daily_data UPDATE received (realtime)');
              }
              schedulePull();
            },
          )
          .subscribe(_onRealtimeStatus);
    } catch (e) {
      if (kDebugMode) debugPrint('[PYLO SYNC] Realtime subscribe failed: $e');
    }
  }

  /// Logs the channel verdict in debug builds only. A `channelError` after a
  /// "subscribed" join is what a missing realtime publication (or a failed
  /// replication setup) looks like — the periodic pull below still covers it.
  void _onRealtimeStatus(RealtimeSubscribeStatus status, Object? error) {
    // While the channel is live, skip the redundant 30 s poll; the moment it
    // drops (closed/timedOut/channelError) fall back to polling so a missed
    // event, a publication outage, or an app-suspend gap never stalls sync.
    final wasUp = _isRealtimeUp;
    if (status == RealtimeSubscribeStatus.subscribed) {
      _isRealtimeUp = true;
      if (!wasUp) _stopCloudRefreshTimer();
    } else {
      _isRealtimeUp = false;
      if (wasUp) _startCloudRefreshTimer();
    }
    if (!kDebugMode) return;
    if (status == RealtimeSubscribeStatus.subscribed) {
      debugPrint('[PYLO SYNC] Realtime subscription started '
          '(user-scoped daily_data)');
    } else if (status == RealtimeSubscribeStatus.closed) {
      debugPrint('[PYLO SYNC] Realtime subscription closed — polling');
    } else if (status == RealtimeSubscribeStatus.timedOut) {
      debugPrint('[PYLO SYNC] Realtime subscription timed out — falling back '
          'to polling');
    } else {
      // channelError: also what a failed server-side replication setup looks
      // like — usually public.daily_data missing from the realtime publication.
      debugPrint('[PYLO SYNC] Realtime error: $error (is public.daily_data in '
          'the supabase_realtime publication?)');
    }
  }

  void _unsubscribeRealtime() {
    _realtimeForUserId = null;
    _isRealtimeUp = false;
    final channel = _realtimeChannel;
    if (channel == null) return;
    _realtimeChannel = null;
    try {
      channel.unsubscribe();
      if (kDebugMode) debugPrint('[PYLO SYNC] Realtime subscription disposed');
    } catch (e) {
      if (kDebugMode) debugPrint('[PYLO SYNC] Realtime unsubscribe failed: $e');
    }
  }

  /// Gentle periodic pull so the app still receives website changes even when
  /// the realtime publication is unavailable or an event was missed.
  void _startCloudRefreshTimer() {
    // While a live realtime subscription is actively pushing changes the 30 s
    // poll is redundant (the status listener restarts it the moment the
    // channel drops), so skip starting it again — e.g. when a fresh session
    // comes in while an existing channel (with a different user) is re-keyed.
    if (_isRealtimeUp) return;
    _stopCloudRefreshTimer();
    _cloudRefreshTimer = Timer.periodic(_cloudRefreshInterval, (_) {
      unawaited(syncFromCloud());
    });
  }

  void _stopCloudRefreshTimer() {
    _cloudRefreshTimer?.cancel();
    _cloudRefreshTimer = null;
  }

  Future<void> _deleteTodayQuietly() async {
    if (!_initialized || !isSignedIn) return;
    final userId = currentUserId;
    if (userId == null) return;
    try {
      await _client
          .from('daily_data')
          .delete()
          .eq('user_id', userId)
          .eq('data_date', localDateKey(DateTime.now()))
          .timeout(_timeout);
      _resetSyncState();
    } catch (e) {
      if (kDebugMode) debugPrint('Cloud delete skipped (offline?): $e');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  static String _hashPayload(String dateKey, DailyCloudData data) {
    return jsonEncode({
      'date': dateKey,
      'tasks': data.tasks,
      'lists': data.lists,
      'sublists': data.sublists,
    }).hashCode.toString();
  }

  void _resetSyncState() {
    _syncedDateKey = null;
    _syncedPayloadHash = null;
    _cloudCompletions = null;
  }

  /// Stable, server-compatible uuid for the `daily_data.id` PK derived from
  /// (user, date) so upserts never regenerate it.
  static const Uuid _uuid = Uuid();

  static String _rowId(String userId, String dateKey) {
    return _uuid.v5(Namespace.url.value, '$userId/$dateKey');
  }

  static String _normalizeEmail(String email) => email.trim().toLowerCase();

  static final RegExp _emailReg = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static String? _validateEmail(String email) {
    if (!_emailReg.hasMatch(email)) {
      return 'Please enter a valid email address.';
    }
    return null;
  }

  /// Truthful, layered error classification.
  ///
  /// Previous logic labelled ANY SocketException/ClientException/TimeoutException
  /// (or a failed single-host probe) as "No internet connection". On Android
  /// those exceptions also occur with a perfectly working connection — a slow
  /// link hitting the request timeout, the carrier/firewall resetting the
  /// connection, the server answering then dropping the socket, a wrong
  /// project URL failing DNS, or the domain being blocked only on the phone's
  /// network. The old single-host probe produced the same false "No internet"
  /// verdict, so it was replaced by a two-target layered probe that compares
  /// the Supabase host against a public control endpoint and reports WHICH
  /// layer failed (DNS / TCP / TLS / HTTP).
  ///
  /// Rules:
  ///  1. A server-answered error (typed AuthException with HTTP status / known
  ///     code) is NEVER reported as "no internet" — it is a server/auth error.
  ///  2. Connection-shaped errors are probed at DNS→TCP→TLS against Supabase
  ///     AND a control endpoint before any "no internet" verdict is issued.
  ///  3. Wrong project key / bad project URL get an explicit config message.
  ///  4. Every failure logs the resolved config + raw error for diagnosis.
  Future<CloudSyncResult> _classify(Object e) async {
    if (kDebugMode) {
      debugPrint('Cloud sync error | config: ${SupabaseConfig.debugDescription()}');
      debugPrint('Cloud sync error | error: ${e.runtimeType}: $e');
    }

    if (e is AuthException) {
      final serverIssue = _mapServerAuthError(e);
      if (serverIssue != null) return serverIssue;
      // gotrue decoded an actual HTTP response (401/400/422/5xx…): the request
      // reached Supabase, so this is a cloud/auth error, never connectivity.
      if (e.statusCode != null) {
        return CloudSyncResult.fail(
          CloudSyncErrorKind.server,
          'Supabase server responded with HTTP ${e.statusCode}'
          '${e.code != null ? ' (${e.code})' : ''}. ${_serverHint(e.statusCode!)}',
        );
      }
    }

    final text = e.toString().toLowerCase();
    final name = e.runtimeType.toString().toLowerCase();
    final networkShaped = name.contains('socketexception') ||
        name.contains('clientexception') ||
        name.contains('timeoutexception') ||
        name.contains('httpexception') ||
        name.contains('authretryablefetchexception') ||
        _isNetworkText(text);

    if (!networkShaped) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.server,
        'The cloud server could not complete the request. Please try again.',
      );
    }

    final baseUri = SupabaseConfig.baseUri;
    if (baseUri == null) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.notConfigured,
        'The configured Supabase URL is invalid. Check SUPABASE_URL.',
      );
    }

    final probe = await net_probe.probeHostReachability(
      baseUri,
      timeout: _probeTimeout,
    );
    switch (probe.status) {
      case net_probe.HostReachability.noInternet:
        return CloudSyncResult.fail(
          CloudSyncErrorKind.network,
          probe.detail,
        );
      case net_probe.HostReachability.cloudUnreachable:
        return CloudSyncResult.fail(
          CloudSyncErrorKind.network,
          probe.detail,
        );
      case net_probe.HostReachability.tlsIssue:
        return CloudSyncResult.fail(
          CloudSyncErrorKind.server,
          probe.detail,
        );
      case net_probe.HostReachability.reachable:
        return const CloudSyncResult.fail(
          CloudSyncErrorKind.server,
          'Supabase is reachable but could not complete the request just now. '
          'It may be temporarily busy — please try again in a moment.',
        );
      case net_probe.HostReachability.unknown:
        return const CloudSyncResult.fail(
          CloudSyncErrorKind.server,
          'Could not verify the connection. Please try again.',
        );
    }
  }

  static String _serverHint(String status) {
    final code = int.tryParse(status);
    if (code != null && code >= 500) {
      return 'The cloud server may be temporarily unavailable.';
    }
    if (status == '401' || status == '403') {
      return 'Check the email/password and that the publishable key '
          '(SUPABASE_ANON_KEY) matches this project.';
    }
    if (status == '404') {
      return 'Check that the project URL (SUPABASE_URL) is correct for this '
          'project.';
    }
    return 'Please try again.';
  }

  /// Maps errors that PROVE the server answered. Non-null result means the
  /// device definitely had connectivity — never a "no internet" report.
  CloudSyncResult? _mapServerAuthError(AuthException e) {
    final code = (e.code ?? '').toLowerCase();
    final message = e.message.toLowerCase();

    if (code.contains('invalid_api_key') ||
        message.contains('invalid api key')) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.notConfigured,
        'Cloud sync is using an invalid project key. Rebuild the app with the '
        'correct --dart-define=SUPABASE_ANON_KEY=<publishable key>.',
      );
    }
    if ((message.contains('project') ||
            message.contains('supabase')) &&
        (message.contains('not found') ||
            message.contains('could not be found') ||
            message.contains('does not exist'))) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.notConfigured,
        'The configured Supabase URL does not match any project. '
        'Check SUPABASE_URL.',
      );
    }
    if (code.contains('invalid_credentials') ||
        message.contains('invalid login credentials')) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.invalidCredentials,
        'Incorrect email or password.',
      );
    }
    if (code.contains('email_not_confirmed') ||
        message.contains('email not confirmed')) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.invalidCredentials,
        'Please confirm your email address first.',
      );
    }
    if (code.contains('user_already_exists') ||
        message.contains('already been registered') ||
        message.contains('already registered')) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.emailTaken,
        'An account with this email already exists.',
      );
    }
    if (code.contains('weak_password') ||
        message.contains('at least 6 characters')) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.weakPassword,
        'Password must be at least 6 characters.',
      );
    }
    if (message.contains('unable to validate email') ||
        message.contains('invalid email')) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.invalidEmail,
        'Please enter a valid email address.',
      );
    }
    if (message.contains('token') && message.contains('expired')) {
      return const CloudSyncResult.fail(
        CloudSyncErrorKind.sessionExpired,
        'Your session expired. Please log in again.',
      );
    }
    return null;
  }

  /// Substrings that indicate a transport-level failure rather than a
  /// decoded API error. Broad by design: anything matching here only *triggers*
  /// a probe, which decides the truth.
  static bool _isNetworkText(String text) {
    const needles = [
      'socketexception',
      'clientexception',
      'no route to host',
      'network is unreachable',
      'host is unreachable',
      'failed to resolve host',
      'connection refused',
      'connection reset',
      'connection timed out',
      'connect timed out',
      'timed out',
      'connect failed',
      'permission denied',
      'broken pipe',
    ];
    return needles.any(text.contains);
  }

  void dispose() {
    _syncDebounce?.cancel();
    _authSub?.cancel();
    _pullDebounce?.cancel();
    _cloudRefreshTimer?.cancel();
    _unsubscribeRealtime();
    remoteDataApplied.dispose();
  }
}