import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import 'core/utils/notification_helper.dart';
import 'core/utils/startup_benchmark.dart';
import 'features/alarm/screens/alarm_screen.dart';
import 'features/auth/screens/app_lock_screen.dart';
import 'providers/birthday_provider.dart';
import 'providers/preferences_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/task_provider.dart';
import 'services/home_widget_service.dart';
import 'services/widget_action_callback.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  StartupBenchmark.reset();
  StartupBenchmark.mark('main_entered');

  // Load the persisted theme BEFORE the first frame so a Dark/AMOLED/Glass
  // user never gets a white Light-theme flash on cold start.
  final initialThemeMode = await loadInitialThemeMode();

  // Install a global error handler so framework/build errors are captured
  // instead of killing the app silently. Errors are logged in debug; in
  // release they are swallowed but the app keeps running.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (kDebugMode) {
      debugPrint('PYLO framework error:\n$details');
    }
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    if (kDebugMode) {
      debugPrint('PYLO platform error: $error\n$stack');
    }
    return true;
  };

  // Initialize timezones synchronously — cheap, needed by notifications later.
  tz_data.initializeTimeZones();

  if (kIsWeb) {
    databaseFactory = databaseFactoryFfiWeb;
  } else if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(
    ProviderScope(
      overrides: [
        initialThemeModeProvider.overrideWith((ref) => initialThemeMode),
      ],
      child: const TaskFlowApp(),
    ),
  );

  StartupBenchmark.mark('run_app_called');
}

class TaskFlowApp extends ConsumerStatefulWidget {
  const TaskFlowApp({super.key});

  @override
  ConsumerState<TaskFlowApp> createState() => _TaskFlowAppState();
}

class _TaskFlowAppState extends ConsumerState<TaskFlowApp>
    with WidgetsBindingObserver {
  /// Root navigator used to present the full-screen alarm over whatever the
  /// app currently shows (task lists, PIN lock, focus screen, …).
  final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

  StreamSubscription<AlarmInfo>? _alarmSub;
  bool _alarmBeingPresented = false;
  DateTime? _resumedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initBackgroundServices());
    });
    // Register the background interactivity callback so widget checkbox taps
    // can toggle tasks even when the app is not in the foreground.
    if (!kIsWeb) registerWidgetCallback();
    // Warm start: an alarm's full-screen intent brought the app forward.
    _alarmSub = NotificationHelper.alarmEvents.listen(_presentAlarm);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _alarmSub?.cancel();
    super.dispose();
  }

  /// When the app returns to the foreground after being away long enough that
  /// a scheduled reminder/reward may have been missed (e.g. the phone was
  /// rebooted, or a reminder was cancelled while the app was paused), re-sync
  /// pending notifications so tomorrow's alarms don't silently go stale.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final now = DateTime.now();
    final lastResume = _resumedAt;
    _resumedAt = now;

    // Only re-arm when returning from a real background interval, not the
    // very first resume (which is handled by _initBackgroundServices).
    if (lastResume == null) return;
    if (now.difference(lastResume).inMinutes < 5) return;

    if (kIsWeb || !mounted) return;
    final prefs = ref.read(settingsPreferencesProvider);
    if (!prefs.notificationsEnabled) return;
    unawaited(ref.read(taskProvider.notifier).rescheduleAllTaskReminders()
        .catchError((e) {
      if (kDebugMode) debugPrint('Resume reschedule failed: $e');
    }));
  }

  Future<void> _presentAlarm(AlarmInfo alarm) async {
    if (!mounted || _alarmBeingPresented) return;
    _alarmBeingPresented = true;
    try {
      final navigator = _rootNavigatorKey.currentState;
      if (navigator == null || NotificationHelper.isAlarmOpen) return;
      await navigator.push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => AlarmScreen(alarm: alarm),
        ),
      );
    } finally {
      _alarmBeingPresented = false;
    }
  }

  Future<void> _initBackgroundServices() async {
    final sw = Stopwatch()..start();
    debugPrint('PYLO_Init start');

    // Settings loaded first (cheap SharedPreferences read) so the theme is
    // correct, then notifications + birthday reschedule in parallel.
    await ref.read(settingsProvider.notifier).ensureLoaded();
    StartupBenchmark.mark('preferences_loaded (${sw.elapsedMilliseconds}ms)');

    if (!kIsWeb) {
      sw.reset();

      // Fast init path first: notifications plugin + widget bridge only, then
      // present any cold-start alarm immediately. The heavier reminder re-arm
      // below runs afterwards in the background and must never gate the
      // alarm UI on launch.
      await Future.wait([
        NotificationHelper.init().catchError((e) {
          if (kDebugMode) debugPrint('NotificationHelper init failed: $e');
        }),
        HomeWidgetService.init().catchError((e) {
          if (kDebugMode) debugPrint('HomeWidget init failed: $e');
        }),
      ]);

      // Cold start: the app was launched directly by a legacy alarm's
      // full-screen intent (already pushed above via the stream on warm
      // starts). Modern task alarms ring natively and never reach this path.
      final pendingAlarm = await NotificationHelper.pendingLaunchAlarm();
      if (pendingAlarm != null) {
        debugPrint('PYLO_ColdStart presenting alarm: ${pendingAlarm.taskTitle}');
        await _presentAlarm(pendingAlarm);
      } else {
        debugPrint('PYLO_ColdStart no pending alarm to present');
      }

      // Background reminder re-arm (task + birthday reschedule in parallel).
      // Note: no HomeWidgetService.pushNow() here — the task/habit providers
      // load immediately after startup and their debounced _flush() already
      // pushes widget data once. An explicit push would double the writes.
      final prefs = ref.read(settingsPreferencesProvider);
      await Future.wait([
        if (prefs.birthdayRemindersEnabled)
          ref.read(birthdayProvider.notifier).rescheduleAllReminders().catchError((e) {
            if (kDebugMode) debugPrint('Birthday reschedule failed: $e');
          }),
        if (prefs.notificationsEnabled)
          ref
              .read(taskProvider.notifier)
              .rescheduleAllTaskReminders()
              .catchError((e) {
            if (kDebugMode) debugPrint('Task reminder reschedule failed: $e');
          }),
      ]);
      debugPrint('PYLO_Init milestone: initializers done (${sw.elapsedMilliseconds}ms)');

      StartupBenchmark
          .mark('notifications_initialized (${sw.elapsedMilliseconds}ms)');
    }

    if (kDebugMode) {
      debugPrint(StartupBenchmark.report());
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(settingsProvider);

    final bool isGlass = themeMode == AppThemeMode.glass;
    final ThemeMode mode = switch (themeMode) {
      AppThemeMode.dark || AppThemeMode.amoled => ThemeMode.dark,
      AppThemeMode.light || AppThemeMode.glass => ThemeMode.light,
    };

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PYLO',
      navigatorKey: _rootNavigatorKey,
      theme: isGlass ? AppTheme.glassTheme : AppTheme.lightTheme,
      darkTheme: themeMode == AppThemeMode.amoled
          ? AppTheme.amoledTheme
          : AppTheme.darkTheme,
      themeMode: mode,
      // Only the Glass theme gets the soft ambient background layer: a dark
      // gradient with a subtle indigo glow that translucent surfaces float on.
      // Dark / Light / AMOLED keep their plain (fast) scaffold backgrounds.
      builder: isGlass ? _glassBackground : null,
      home: const AppLockGate(),
    );
  }

  Widget _glassBackground(BuildContext context, Widget? child) {
    return DecoratedBox(
      position: DecorationPosition.background,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, 0.5, 1.0],
          colors: [
            GlassColors.bgGradientStart,
            GlassColors.bg,
            GlassColors.bgGradientEnd,
          ],
        ),
      ),
      child: Stack(
        children: [
          // Ambient lighting glows that give the glass depth. These are
          // static (never animated) so blur cost stays zero here. Alphas are
          // kept very low so the ambience reads as a soft sheen, never as a
          // colored screen.
          Positioned(
            top: -80,
            right: -60,
            child: _ambientOrb(
              size: 260,
              color: GlassColors.glow,
            ),
          ),
          Positioned(
            bottom: -100,
            left: -80,
            child: _ambientOrb(
              size: 300,
              color: GlassColors.glowSoft,
            ),
          ),
          child ?? const SizedBox.shrink(),
        ],
      ),
    );
  }

  /// A static radial "orb" that softly tints the ambient background. Uses
  /// only a gradient (no ImageFilter) so it costs nothing at runtime.
  Widget _ambientOrb({
    required double size,
    required Color color,
  }) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0.0)],
            radius: 1.0,
          ),
        ),
      ),
    );
  }
}
