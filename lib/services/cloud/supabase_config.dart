/// Build-time configuration for the optional PYLO cloud sync.
///
/// The Supabase project URL is public and safe to ship. The publishable
/// (anon) key is intended for clients, but it is still injected at build time
/// via `--dart-define` so it can never be committed to the repository by
/// accident.
///
/// Configure it when running/building the app:
///
/// ```
/// flutter run --dart-define=SUPABASE_ANON_KEY=<publishable_key>
/// ```
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

  /// One-line startup diagnostic of the FINAL URL actually being passed to
  /// Supabase.initialize(). The URL is public; this logs the full value so a
  /// wrong/typo'd/stale hostname is visible at a glance. It prints the key's
  /// LENGTH only, never the key itself.
  static String debugDescription() {
    if (!isConfigured) return 'not configured (key=${anonKey.isEmpty ? 'empty' : 'set'})';
    return 'url=$url anonKeyLength=${anonKey.length}';
  }
}