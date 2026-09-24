import 'cloud_config_store.dart';

/// Build-time configuration for the optional PYLO cloud sync.
///
/// The Supabase project URL is public and safe to ship. The publishable
/// (anon) key is intended for clients, but it is still injected at build time
/// via `--dart-define` so it can never be committed to the repository by
/// accident.
///
/// This is also the DEFAULT project the app dials when the user has not
/// connected their own Supabase project (Settings → Web Access is "bring your
/// own cloud" and always wins when one is stored). A release built without the
/// define ships fully offline, exactly as before.
///
/// Configure it when running/building the app:
///
/// ```
/// flutter build apk --release --dart-define=SUPABASE_ANON_KEY=<publishable_key>
/// ```
///
/// For local development use the git-ignored define file
/// `dart_defines/.env.local` (see `build_release_apk.ps1`), which feeds the
/// same constant via `--dart-define-from-file`.
class SupabaseConfig {
  SupabaseConfig._();

  /// THE single source of truth for the Supabase project URL — copied exactly
  /// from the dashboard. Deliberately NOT overridable via --dart-define: a
  /// stray `SUPABASE_URL` define previously overwrote the correct value and
  /// made the app dial a non-existent hostname (the "DNS lookup failed"
  /// false alarm). Never construct this from the project ID and never append
  /// /rest/v1 to it — the SDK adds API sub-paths itself.
  static const String url = 'https://jfeunxepvrpixktharxk.supabase.co';

  static const String anonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// True when cloud sync can actually dial out: a publishable key AND a
  /// parseable HTTPS URL pointing at a real host. An empty/garbled value here
  /// is exactly what used to surface as a confusing "no internet" report.
  static bool get isConfigured {
    if (anonKey.isEmpty) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  /// Parsed project URL, or null when the configured string is malformed.
  /// Used by the error-path reachability probe.
  static Uri? get baseUri => Uri.tryParse(url);

  /// The build-time default [CloudConfig] the sync service uses when the user
  /// hasn't connected their own project yet. Null when the anon key wasn't
  /// supplied at build time — the app then stays fully offline. The key value
  /// itself is never surfaced anywhere.
  static CloudConfig? toCloudConfig() {
    if (!isConfigured) return null;
    return const CloudConfig(url: url, anonKey: anonKey);
  }

  /// One-line startup diagnostic of the FINAL URL actually being passed to
  /// Supabase.initialize(). The URL is public; this logs the full value so a
  /// wrong/typo'd/stale hostname is visible at a glance. It prints the key's
  /// LENGTH only, never the key itself.
  static String debugDescription() {
    if (!isConfigured) return 'not configured (key=${anonKey.isEmpty ? 'empty' : 'set'})';
    return 'url=$url anonKeyLength=${anonKey.length}';
  }
}