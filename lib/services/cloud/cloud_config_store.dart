import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A Supabase project the user typed into the Create Account sheet. Never a
/// hardcoded developer value: PYLO's own project URL/key is a dev reference
/// only and is never used to back an end user's sync.
class CloudConfig {
  const CloudConfig({required this.url, required this.anonKey});

  final String url;
  final String anonKey;

  /// True when the value can actually dial out: a non-empty anon/public key AND
  /// an https URL pointing at a real host (Supabase project URLs look like
  /// `https://<project-ref>.supabase.co`). Used as the cheap gate before any
  /// network work.
  bool get isConfigured {
    if (anonKey.trim().isEmpty) return false;
    final uri = baseUri;
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.host.contains('.');
  }

  Uri? get baseUri => Uri.tryParse(url.trim());

  bool sameAs(CloudConfig other) => other.url == url && other.anonKey == anonKey;

  /// The `<ref>` subdomain of a Supabase project URL (e.g. `abcd1234` for
  /// `https://abcd1234.supabase.co`). Scopes the persisted auth-session key so
  /// two different projects can never read each other's stored session.
  String? get projectRef {
    final host = baseUri?.host;
    if (host == null) return null;
    final first = host.split('.').first.trim();
    return first.isEmpty ? null : first;
  }

  /// One-line diagnostic. The anon key is a publishable client key, but only
  /// its presence/length is ever reported — never the key itself.
  String debugDescription() {
    if (!isConfigured) {
      return 'not connected (key=${anonKey.isEmpty ? 'empty' : 'set'})';
    }
    return 'url=${baseUri?.host} anonKeyLength=${anonKey.length}';
  }

  @override
  String toString() => debugDescription();
}

/// App-wide user-chosen Supabase project, held in `flutter_secure_storage`
/// (the same backend the app lock PIN and face templates use). The app is a
/// single-local-profile device, so there is no per-user account table to key
/// into — the stored project simply belongs to whoever owns this device.
///
/// A fresh install has no config: `current` is null, `isConfigured` is false
/// and every cloud path silently no-ops (full offline mode).
class CloudConfigStore {
  CloudConfigStore({FlutterSecureStorage? storage})
      : _storage =
            storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  static const _urlKey = 'pylo_cloud_sync_url';
  static const _anonKeyKey = 'pylo_cloud_sync_anon_key';

  final FlutterSecureStorage _storage;

  CloudConfig? _cached;
  Future<CloudConfig?>? _loading;
  bool _loadedOnce = false;

  /// Bumped by [save] / [clear] so an in-flight [load] that already read the
  /// storage can never clobber `_cached` with a stale (pre-write) value.
  int _generation = 0;

  /// The stored project, or null when the user never connected one.
  CloudConfig? get current => _cached;

  /// True once the store has finished reading secure storage at least once.
  bool get isLoaded => _loadedOnce;

  /// Loads the stored project ONCE and (never throws). Single-flight: every
  /// caller awaits the same read, so a startup that both warms the cache and
  /// initializes the sync service can never see a stale `null` for a config
  /// that really is stored. [save] / [clear] bump the generation so an in-flight
  /// read that already returned cannot overwrite a just-written config.
  Future<CloudConfig?> load() {
    if (_cached != null) {
      _loadedOnce = true;
      return Future.value(_cached);
    }
    return _loading ??= _readFromStorage().then((config) {
      _loading = null;
      _loadedOnce = true;
      return config;
    });
  }

  Future<CloudConfig?> _readFromStorage() async {
    try {
      final generation = _generation;
      final url = await _storage.read(key: _urlKey);
      final key = await _storage.read(key: _anonKeyKey);
      if (generation != _generation) return _cached;
      _cached =
          (url == null || url.isEmpty || key == null || key.isEmpty)
              ? null
              : CloudConfig(url: url, anonKey: key);
      return _cached;
    } catch (_) {
      return _cached;
    }
  }

  Future<void> save(CloudConfig config) async {
    // Invalidate any in-flight load BEFORE mutating, so the writes below can
    // never be overwritten by a read that already captured the old state.
    _generation++;
    _cached = config;
    try {
      await _storage.write(key: _urlKey, value: config.url.trim());
      await _storage.write(key: _anonKeyKey, value: config.anonKey.trim());
    } catch (_) {
      // Best-effort: a failed write keeps the last known config in memory.
    }
    _cached = config;
  }

  Future<void> clear() async {
    // Invalidate any in-flight load first: its read already captured the
    // pre-clear state and must not repopulate the cache afterwards.
    _generation++;
    _cached = null;
    try {
      await _storage.delete(key: _urlKey);
      await _storage.delete(key: _anonKeyKey);
    } catch (_) {}
    _cached = null;
  }
}