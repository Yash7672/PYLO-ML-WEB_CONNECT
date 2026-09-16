import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode { light, dark, amoled, glass }

/// Reads the persisted theme mode synchronously-ish BEFORE runApp so the
/// very first frame already uses the correct theme. Without this, a user
/// with Dark/AMOLED/Glass selected would always see a white Light-theme
/// flash on cold start. Falls back to light when nothing is stored.
Future<AppThemeMode> loadInitialThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return switch (prefs.getString('theme_mode')) {
      'dark' => AppThemeMode.dark,
      'amoled' => AppThemeMode.amoled,
      'glass' => AppThemeMode.glass,
      _ => AppThemeMode.light,
    };
  } catch (_) {
    return AppThemeMode.light;
  }
}

class SettingsController extends StateNotifier<AppThemeMode> {
  SettingsController({AppThemeMode initialMode = AppThemeMode.light})
      : super(initialMode) {
    _load();
  }

  Completer<void>? _loading;
  SharedPreferences? _cachedPrefs;

  Future<SharedPreferences> _getPrefs() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  Future<void> ensureLoaded() {
    if (_loading != null) return _loading!.future;
    return _load();
  }

  Future<void> _load() async {
    final completer = Completer<void>();
    _loading = completer;
    try {
      final prefs = await _getPrefs();
      final stored = prefs.getString('theme_mode');
      if (stored == 'dark') {
        state = AppThemeMode.dark;
      } else if (stored == 'amoled') {
        state = AppThemeMode.amoled;
      } else if (stored == 'glass') {
        state = AppThemeMode.glass;
      } else {
        state = AppThemeMode.light;
      }
      completer.complete();
    } catch (e) {
      completer.completeError(e);
    } finally {
      _loading = null;
    }
  }

  Future<void> setTheme(AppThemeMode mode) async {
    final prefs = await _getPrefs();
    state = mode;
    await prefs.setString('theme_mode', mode.name);
  }
}final settingsProvider =
    StateNotifierProvider<SettingsController, AppThemeMode>((ref) {
  return SettingsController(
      initialMode:
          ref.watch(initialThemeModeProvider) ?? AppThemeMode.light);
});

/// Optional override injected at app bootstrap (see main.dart). Stays null
/// in tests or when the theme was not pre-loaded.
final initialThemeModeProvider =
    StateProvider<AppThemeMode?>((ref) => null);
