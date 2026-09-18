import 'package:flutter/material.dart';

/// Theme extension marker that is present ONLY inside the Glass theme.
///
/// Widgets can check `PyloGlass.isActive(context)` to apply glass-specific
/// visuals (blur, translucent surfaces) without ever affecting Dark, Light
/// or AMOLED themes.
class PyloGlass extends ThemeExtension<PyloGlass> {
  const PyloGlass();

  static bool isActive(BuildContext context) =>
      Theme.of(context).extension<PyloGlass>() != null;

  @override
  PyloGlass copyWith() => const PyloGlass();

  @override
  PyloGlass lerp(ThemeExtension<PyloGlass>? other, double t) =>
      other is PyloGlass ? other : const PyloGlass();
}

/// Frosted-glass color palette shared by the Glass theme and its widgets.
///
/// This is a COMPLETE, self-contained color system. Surfaces are DARK and
/// semi-transparent (a dark navy tint with varying alpha) so they always read
/// as "dark tinted glass" — never as white cards. White appears only in text,
/// icons and hairline borders.
class GlassColors {
  // Background (the ambient gradient lives in main.dart's _glassBackground)
  static const Color bg = Color(0xFF0B0B16);
  static const Color bgGradientStart = Color(0xFF12122A);
  static const Color bgGradientEnd = Color(0xFF05050C);

  // Opaque surfaces (dialogs, sheets, menus — where translucency would hurt
  // readability or leak whatever is scrolling underneath)
  static const Color surfaceOpaque = Color(0xFF171A2B);
  static const Color surfaceOpaqueDark = Color(0xFF171A2B);

  // Surface levels — each floats above the previous one.
  // DARK translucent tints: the higher the level, the more opaque (content
  // behind a card/sheet is never readable through it).
  static const Color level1 = Color(0xC9141828); // background glass  (~79%)
  static const Color level2 = Color(0xE8181C2E); // standard glass    (~91%)
  static const Color level3 = Color(0xF51E2338); // floating glass    (~96%)

  // Control surfaces (pressed/hover states build on the levels above)
  static const Color surface = level1;
  static const Color surfaceStrong = level2;
  static const Color surfacePressed = level3;

  // Borders — thin, low-opacity white hairlines that read as "glass edge".
  static const Color border = Color(0x1AFFFFFF);
  static const Color borderMedium = Color(0x2BFFFFFF);
  static const Color borderStrong = Color(0x3DFFFFFF);

  // Text
  static const Color textPrimary = Color(0xFFF2F3F7);
  static const Color textSecondary = Color(0xE6F2F3F7);
  static const Color textMuted = Color(0x99F2F3F7);
  static const Color textFaint = Color(0x66F2F3F7);

  // Accent — PYLO amber/orange. An ACCENT, never a background.
  static const Color accent = Color(0xFFFFB74D);
  static const Color accentStrong = Color(0xFFFF9D2B);
  static const Color accentDeep = Color(0xFFF57C00);
  static const Color accentSubtle = Color(0x26FFB74D);
  static const Color accentGlow = Color(0x40FFB74D);

  // Dark ink used ON TOP of amber fills (selected days, primary buttons).
  static const Color onAccent = Color(0xFF221704);

  // Legacy names kept for backwards compatibility with existing widgets.
  // They now resolve into the amber accent system.
  static const Color deepAccent = accentStrong;
  static const Color deepAccentStrong = accentDeep;
  static const Color deepAccentGlow = accentGlow;

  // Functional colors
  static const Color success = Color(0xFF66BB6A);
  static const Color successSubtle = Color(0x1F66BB6A);
  static const Color warning = Color(0xFFFFB74D);
  static const Color warningSubtle = Color(0x26FFB74D);
  static const Color error = Color(0xFFEF5350);
  static const Color errorSubtle = Color(0x29EF5350);

  // Ambient lighting used by the background gradient (extremely subtle:
  // one cool indigo orb + one warm amber orb behind the glass).
  static const Color glow = Color(0x1E5B4FC8);
  static const Color glowSoft = Color(0x26FFB74D);
}

class AppTheme {
  static late final ThemeData _lightTheme;
  static late final ThemeData _darkTheme;
  static late final ThemeData _amoledTheme;
  static late final ThemeData _glassTheme;
  static bool _initialized = false;

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;

    _lightTheme = _base(Brightness.light);
    _darkTheme = _base(Brightness.dark);

    _amoledTheme = _darkTheme.copyWith(
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: _darkTheme.appBarTheme.copyWith(
        backgroundColor: Colors.black,
      ),
      colorScheme: _darkTheme.colorScheme.copyWith(
        surface: Colors.black,
        surfaceContainerHighest: const Color(0xFF1E1E1E),
      ),
      cardTheme: _darkTheme.cardTheme.copyWith(
        color: const Color(0xFF1E1E1E),
      ),
    );

    _glassTheme = _buildGlass();
  }

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      colorScheme: colorScheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFF8F7FC),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF8F7FC),
        foregroundColor: isDark ? Colors.white : const Color(0xFF1D1B20),
      ),
      cardTheme: CardThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        elevation: 0,
        color: isDark ? const Color(0xFF1E1E20) : Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF1A1A1C) : Colors.white,
        indicatorColor: colorScheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
    );
  }

  /// The Glass theme — a premium dark "frosted glass" design system.
  ///
  /// Translucent DARK surfaces float on a soft ambient gradient background
  /// with three visible depth levels. Blur is applied selectively (the
  /// GlassSurface component, the floating nav), never to every widget, so the
  /// theme stays smooth on real hardware. The ColorScheme is overridden in
  /// FULL so no default Material palette (which contains light lavender  /// containers) can leak through any component.
  static ThemeData _buildGlass() {
    final baseDark = _darkTheme;

    final scheme = baseDark.colorScheme.copyWith(
      // Amber accent system
      primary: GlassColors.accent,
      onPrimary: GlassColors.onAccent,
      primaryContainer: GlassColors.accentSubtle,
      onPrimaryContainer: GlassColors.textPrimary,
      secondary: GlassColors.accentStrong,
      onSecondary: GlassColors.onAccent,
      secondaryContainer: GlassColors.accentSubtle,
      onSecondaryContainer: GlassColors.textPrimary,
      tertiary: GlassColors.accentDeep,
      onTertiary: GlassColors.onAccent,
      tertiaryContainer: GlassColors.accentSubtle,
      onTertiaryContainer: GlassColors.textPrimary,
      // Error
      error: GlassColors.error,
      onError: const Color(0xFF160607),
      errorContainer: GlassColors.errorSubtle,
      onErrorContainer: const Color(0xFFFFB4AB),
      // Surfaces — dark translucent glass at every container level
      surface: GlassColors.level1,
      onSurface: GlassColors.textPrimary,
      onSurfaceVariant: GlassColors.textSecondary,
      surfaceContainerLowest: GlassColors.level1,
      surfaceContainerLow: GlassColors.level1,
      surfaceContainer: GlassColors.level2,
      surfaceContainerHigh: GlassColors.level2,
      surfaceContainerHighest: GlassColors.level3,
      surfaceTint: Colors.transparent,
      // Borders / misc
      outline: GlassColors.borderStrong,
      outlineVariant: GlassColors.border,
      inversePrimary: GlassColors.accent,
      inverseSurface: const Color(0xFFE4E2EE),
      onInverseSurface: const Color(0xFF15141A),
      scrim: Colors.black,
      shadow: Colors.black,
    );

    const borderOutline = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
      borderSide: BorderSide(color: GlassColors.borderMedium, width: 1),
    );
    const focusedOutline = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
      borderSide: BorderSide(color: GlassColors.accent, width: 1.5),
    );

    return baseDark.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      // ROOT CAUSE FIX for transparent dropdowns: DropdownButton paints its
      // open menu panel with ThemeData.canvasColor (it has no per-button
      // background here), which used to be fully transparent — so the page
      // text behind an open Priority/Category/Repeat menu bled straight
      // through it. canvasColor must be OPAQUE. The ambient gradient still
      // shows everywhere else because Scaffold/AppBar/NavigationBar use their
      // own transparent backgrounds above it.
      canvasColor: GlassColors.surfaceOpaque,
      colorScheme: scheme,
      iconTheme: const IconThemeData(color: GlassColors.textPrimary),
      primaryIconTheme: const IconThemeData(color: GlassColors.textPrimary),
      textTheme: baseDark.textTheme.apply(
        bodyColor: GlassColors.textPrimary,
        displayColor: GlassColors.textPrimary,
        fontFamily: 'Inter',
      ),
      primaryTextTheme: baseDark.primaryTextTheme.apply(
        bodyColor: GlassColors.textPrimary,
        displayColor: GlassColors.textPrimary,
        fontFamily: 'Inter',
      ),
      appBarTheme: baseDark.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        foregroundColor: GlassColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: const TextStyle(
          color: GlassColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
      ),
      cardTheme: const CardThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
          side: BorderSide(color: GlassColors.border, width: 1),
        ),
        elevation: 2,
        color: GlassColors.level2,
        shadowColor: Color(0x33000000),
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: GlassColors.surfaceOpaqueDark,
        surfaceTintColor: Colors.transparent,
        iconColor: GlassColors.textSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: GlassColors.borderMedium, width: 1),
        ),
        titleTextStyle: TextStyle(
          color: GlassColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          fontFamily: 'Inter',
        ),
        contentTextStyle: TextStyle(
          color: GlassColors.textSecondary,
          fontSize: 15,
          height: 1.4,
          fontFamily: 'Inter',
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: GlassColors.surfaceOpaqueDark,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: GlassColors.borderStrong,
        modalBarrierColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: GlassColors.borderMedium),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        // Near-opaque fill so typed text stays crisp and the field never lets
        // scrolled content glyph through while a dropdown is open over it.
        fillColor: GlassColors.level3,
        labelStyle: TextStyle(color: GlassColors.textSecondary),
        hintStyle: TextStyle(color: GlassColors.textMuted),
        prefixIconColor: GlassColors.textSecondary,
        suffixIconColor: GlassColors.textSecondary,
        border: borderOutline,
        enabledBorder: borderOutline,
        focusedBorder: focusedOutline,
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: GlassColors.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: GlassColors.error, width: 1.5),
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: GlassColors.accent,
        selectionColor: GlassColors.accentSubtle,
        selectionHandleColor: GlassColors.accent,
      ),
      dividerTheme: const DividerThemeData(
        color: GlassColors.border,
        thickness: 1,
        space: 1,
      ),
      navigationRailTheme: baseDark.navigationRailTheme.copyWith(
        backgroundColor: Colors.transparent,
        indicatorColor: GlassColors.accentSubtle,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: GlassColors.accent,
        linearTrackColor: GlassColors.borderStrong,
        circularTrackColor: GlassColors.borderStrong,
      ),
      sliderTheme: baseDark.sliderTheme.copyWith(
        activeTrackColor: GlassColors.accent,
        inactiveTrackColor: GlassColors.borderStrong,
        thumbColor: GlassColors.accent,
        overlayColor: GlassColors.accentSubtle,
        valueIndicatorColor: GlassColors.surfaceOpaque,
        valueIndicatorTextStyle: const TextStyle(
          color: GlassColors.textPrimary,
          fontFamily: 'Inter',
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.onAccent;
          }
          return GlassColors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.accent;
          }
          return GlassColors.level2;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith(
            (states) => Colors.transparent),
        trackOutlineWidth: const WidgetStatePropertyAll(0),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.accent;
          }
          return Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll(GlassColors.onAccent),
        side: const BorderSide(color: GlassColors.borderStrong, width: 1.5),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.accent;
          }
          return GlassColors.textMuted;
        }),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: Colors.transparent,
        indicatorColor: GlassColors.accent.withValues(alpha: 0.20),
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? GlassColors.accent
                : GlassColors.textMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? GlassColors.accent
                : GlassColors.textSecondary,
          );
        }),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: GlassColors.accent,
        foregroundColor: GlassColors.onAccent,
        elevation: 4,
        hoverElevation: 6,
        focusElevation: 6,
        highlightElevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: GlassColors.textSecondary,
        textColor: GlassColors.textPrimary,
        subtitleTextStyle: TextStyle(
          color: GlassColors.textMuted,
          fontSize: 13,
          fontFamily: 'Inter',
        ),
        tileColor: Colors.transparent,
      ),
      chipTheme: baseDark.chipTheme.copyWith(
        backgroundColor: GlassColors.level2,
        side: const BorderSide(color: GlassColors.borderMedium, width: 1),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        labelStyle: const TextStyle(
            color: GlassColors.textSecondary, fontFamily: 'Inter'),
        selectedColor: GlassColors.accentSubtle,
        checkmarkColor: GlassColors.accent,
        secondaryLabelStyle:
            const TextStyle(color: GlassColors.textSecondary, fontFamily: 'Inter'),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: GlassColors.surfaceOpaqueDark,
        surfaceTintColor: Colors.transparent,
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: GlassColors.borderMedium, width: 1),
        ),
        textStyle: TextStyle(
          color: GlassColors.textPrimary,
          fontFamily: 'Inter',
        ),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            color: GlassColors.textPrimary,
            fontFamily: 'Inter',
          ),
        ),
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        textStyle: TextStyle(color: GlassColors.textPrimary, fontFamily: 'Inter'),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: GlassColors.surfaceOpaqueDark,
        contentTextStyle: TextStyle(
            color: GlassColors.textPrimary, fontFamily: 'Inter'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: GlassColors.borderMedium, width: 1),
        ),
        actionTextColor: GlassColors.accent,
        closeIconColor: GlassColors.textSecondary,
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: GlassColors.surfaceOpaqueDark,
          borderRadius: BorderRadius.all(Radius.circular(10)),
          border: Border.fromBorderSide(
              BorderSide(color: GlassColors.borderMedium)),
        ),
        textStyle: TextStyle(
          color: GlassColors.textPrimary,
          fontSize: 13,
          fontFamily: 'Inter',
        ),
        waitDuration: Duration(milliseconds: 600),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: GlassColors.textPrimary,
          backgroundColor: GlassColors.level2,
          side: const BorderSide(color: GlassColors.borderStrong, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: GlassColors.accent,
          foregroundColor: GlassColors.onAccent,
          disabledBackgroundColor: GlassColors.level2,
          disabledForegroundColor: GlassColors.textMuted,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: GlassColors.accent,
          foregroundColor: GlassColors.onAccent,
          disabledBackgroundColor: GlassColors.level2,
          disabledForegroundColor: GlassColors.textMuted,
          elevation: 2,
          shadowColor: GlassColors.accentGlow,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: GlassColors.accent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
      ),
      tabBarTheme: baseDark.tabBarTheme.copyWith(
        indicatorColor: GlassColors.accent,
        labelColor: GlassColors.textPrimary,
        unselectedLabelColor: GlassColors.textMuted,
        dividerColor: GlassColors.border,
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: GlassColors.surfaceOpaqueDark,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: GlassColors.borderMedium),
        ),
        hourMinuteColor: GlassColors.level2,
        hourMinuteTextColor: GlassColors.textPrimary,
        hourMinuteShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        // Selected AM/PM becomes a solid amber pill with dark ink so the
        // choice is unmistakable; unselected stays a dark glass surface.
        dayPeriodColor: WidgetStateColor.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.accent;
          }
          return GlassColors.level1;
        }),
        dayPeriodBorderSide:
            const BorderSide(color: GlassColors.borderStrong),
        dayPeriodTextColor: WidgetStateColor.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.onAccent;
          }
          return GlassColors.textSecondary;
        }),
        dialBackgroundColor: GlassColors.level2,
        // The selected dial label is painted ON TOP of the amber hand dot, so
        // amber text on the amber hand is invisible. Dark ink keeps both the
        // hour and minute (00-55) dial values legible while still highlighting
        // which one is selected.
        dialTextColor: WidgetStateColor.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.onAccent;
          }
          return GlassColors.textSecondary;
        }),
        dialHandColor: GlassColors.accent,
        entryModeIconColor: GlassColors.textSecondary,
        helpTextStyle: const TextStyle(
          color: GlassColors.textMuted,
          fontFamily: 'Inter',
        ),
        cancelButtonStyle:
            TextButton.styleFrom(foregroundColor: GlassColors.textSecondary),
        confirmButtonStyle:
            TextButton.styleFrom(foregroundColor: GlassColors.accent),
        timeSelectorSeparatorColor:
            const WidgetStatePropertyAll(GlassColors.textMuted),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: GlassColors.surfaceOpaqueDark,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: GlassColors.borderMedium),
        ),
        headerBackgroundColor: GlassColors.level2,
        headerForegroundColor: GlassColors.textPrimary,
        headerHeadlineStyle: const TextStyle(
          color: GlassColors.textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          fontFamily: 'Inter',
        ),
        headerHelpStyle: const TextStyle(
          color: GlassColors.textMuted,
          fontFamily: 'Inter',
        ),
        dayBackgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GlassColors.accent;
          }
          return Colors.transparent;
        }),
        dayOverlayColor: const WidgetStatePropertyAll(GlassColors.accentSubtle),
        rangeSelectionBackgroundColor: GlassColors.accentSubtle,
        rangePickerBackgroundColor: GlassColors.surfaceOpaqueDark,
        rangePickerHeaderBackgroundColor: Colors.transparent,
        rangePickerHeaderForegroundColor: GlassColors.textPrimary,
        rangePickerHeaderHeadlineStyle: const TextStyle(
          color: GlassColors.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          fontFamily: 'Inter',
        ),
        rangePickerShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          side: BorderSide(color: GlassColors.borderMedium),
        ),
        dividerColor: GlassColors.border,
        cancelButtonStyle:
            TextButton.styleFrom(foregroundColor: GlassColors.textSecondary),
        confirmButtonStyle:
            TextButton.styleFrom(foregroundColor: GlassColors.accent),
        yearOverlayColor: const WidgetStatePropertyAll(GlassColors.accentSubtle),
      ),
      extensions: const [PyloGlass()],
    );
  }

  static ThemeData get lightTheme {
    _ensureInitialized();
    return _lightTheme;
  }

  static ThemeData get darkTheme {
    _ensureInitialized();
    return _darkTheme;
  }

  static ThemeData get amoledTheme {
    _ensureInitialized();
    return _amoledTheme;
  }

  static ThemeData get glassTheme {
    _ensureInitialized();
    return _glassTheme;
  }
}