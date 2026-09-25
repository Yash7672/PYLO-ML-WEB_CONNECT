import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CloudConfig {
  const CloudConfig({required String url, required String anonKey})
      : _url = url,
        _anonKey = anonKey;

  static final RegExp _projectRefReg =
      RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

  final String _url;
  final String _anonKey;

  String get url => _url.trim().replaceFirst(RegExp(r'/+$'), '');
  String get anonKey => _anonKey.trim();

  String? get validationError {
    final urlError = _urlValidationError;
    if (urlError != null) return urlError;
    return _keyValidationError;
  }

  bool get isConfigured => validationError == null;

  Uri? get baseUri {
    final uri = Uri.tryParse(url);
    if (uri == null || _urlValidationError != null) return null;
    return uri;
  }

  String? get _urlValidationError {
    final value = url;
    if (value.isEmpty) return 'Enter the Supabase Project URL.';

    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        RegExp(r':[0-9]+(?:$|[/?#])').hasMatch(value) ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        value.contains('?') ||
        value.contains('#') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return 'Enter a valid Supabase Project URL.';
    }

    final host = uri.host.toLowerCase();
    if (!host.endsWith('.supabase.co')) {
      return 'Enter a valid Supabase Project URL.';
    }
    final projectRef = host.substring(0, host.length - '.supabase.co'.length);
    if (!_projectRefReg.hasMatch(projectRef)) {
      return 'Enter a valid Supabase Project URL.';
    }
    return null;
  }

  String? get _keyValidationError {
    final value = anonKey;
    if (value.isEmpty) return 'Enter the anon/public key.';

    final lower = value.toLowerCase();
    if (lower.startsWith('sb_secret_') || lower.contains('service_role')) {
      return 'Use the project\'s anon or publishable key, not a secret key.';
    }
    if (RegExp(r'^sb_publishable_[A-Za-z0-9_-]+$').hasMatch(value)) {
      return null;
    }

    final parts = value.split('.');
    if (parts.length != 3 ||
        parts.any((part) =>
            part.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(part))) {
      return 'Enter a valid anon or publishable key.';
    }
    final header = _decodeJwtPart(parts[0]);
    final payload = _decodeJwtPart(parts[1]);
    if (header == null || payload == null || header['alg'] is! String) {
      return 'Enter a valid anon or publishable key.';
    }
    if (payload['role'] != 'anon') {
      return 'Use the project\'s anon or publishable key, not a secret key.';
    }
    return null;
  }

  static Map<String, dynamic>? _decodeJwtPart(String part) {
    try {
      final padded = part.padRight((part.length + 3) & ~3, '=');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  bool sameAs(CloudConfig other) =>
      other.url == url && other.anonKey == anonKey;

  String? get projectRef {
    final host = baseUri?.host;
    if (host == null) return null;
    return host.substring(0, host.length - '.supabase.co'.length);
  }

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
  Future<void> _mutationQueue = Future<void>.value();
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
    final loading = _loading;
    if (loading != null) return loading;
    final future = _loadFromStorage();
    _loading = future;
    future.whenComplete(() {
      if (identical(_loading, future)) _loading = null;
    });
    return future;
  }

  Future<CloudConfig?> _loadFromStorage() async {
    while (true) {
      final queue = _mutationQueue;
      await queue;
      if (!identical(queue, _mutationQueue)) continue;
      if (_cached != null) {
        _loadedOnce = true;
        return _cached;
      }
      final generation = _generation;
      final config = await _readFromStorage(generation, queue);
      if (generation != _generation || !identical(queue, _mutationQueue)) {
        continue;
      }
      if (_cached != null) {
        _loadedOnce = true;
        return _cached;
      }
      _loadedOnce = true;
      return config;
    }
  }

  Future<CloudConfig?> _readFromStorage(
    int generation,
    Future<void> queue,
  ) async {
    try {
      final url = await _storage.read(key: _urlKey);
      final key = await _storage.read(key: _anonKeyKey);
      if (generation != _generation || !identical(queue, _mutationQueue)) {
        return _cached;
      }
      _cached = (url == null || url.isEmpty || key == null || key.isEmpty)
          ? null
          : CloudConfig(url: url, anonKey: key);
      return _cached;
    } catch (_) {
      return _cached;
    }
  }

  Future<void> save(CloudConfig config) {
    return _enqueueMutation(() async {
      _generation++;
      _cached = config;
      try {
        await _storage.write(key: _urlKey, value: config.url);
        await _storage.write(key: _anonKeyKey, value: config.anonKey);
      } catch (_) {}
      _cached = config;
    });
  }

  Future<void> clear() {
    return _enqueueMutation(() async {
      _generation++;
      _cached = null;
      try {
        await _storage.delete(key: _urlKey);
        await _storage.delete(key: _anonKeyKey);
      } catch (_) {}
      _cached = null;
    });
  }

  Future<void> _enqueueMutation(Future<void> Function() mutation) async {
    final previous = _mutationQueue;
    final release = Completer<void>();
    _mutationQueue = release.future;
    await previous;
    try {
      await mutation();
    } finally {
      release.complete();
    }
  }
}
