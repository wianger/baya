import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:app/ui/core/themes/app_colors.dart';
import 'package:app/ui/core/themes/app_typography.dart';

/// Builds the [ThemeData] for a given [AppColors] / [AppTypography] pair.
///
/// Wires the semantic tokens into both the standard Material [ColorScheme]
/// (so framework widgets — dialogs, switches, progress indicators, text
/// fields — render correctly per brightness) AND attaches [AppColors] /
/// [AppTypography] as theme extensions (so app widgets read
/// `context.colors.*` / `context.typo.*`).
ThemeData _buildTheme({
  required Brightness brightness,
  required AppColors colors,
  required AppTypography typo,
}) {
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: kSansFamily,
    fontFamilyFallback: kFontFallback,
    scaffoldBackgroundColor: colors.bg,
    colorScheme: ColorScheme(
      brightness: brightness,
      surface: colors.bg,
      onSurface: colors.text,
      primary: colors.accent,
      onPrimary: colors.onAccent,
      primaryContainer: colors.userBubble,
      onPrimaryContainer: colors.text,
      secondary: colors.muted,
      onSecondary: colors.text,
      secondaryContainer: colors.userBubble,
      onSecondaryContainer: colors.text,
      surfaceContainer: colors.surface,
      surfaceContainerHighest: colors.userBubble,
      error: colors.error,
      onError: colors.onAccent,
      outline: colors.border,
    ),
    dividerColor: colors.border,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.standard,
    extensions: <ThemeExtension<dynamic>>[colors, typo],
    // Android 16 makes predictive back the system default. The Cupertino
    // edge swipe competes with the system gesture there, so Android follows
    // the platform: the previous page peeks in while the back gesture runs.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.bg,
      foregroundColor: colors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      titleTextStyle: TextStyle(
        fontFamily: kSansFamily,
        fontFamilyFallback: kFontFallback,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: colors.text,
        letterSpacing: -0.2,
      ),
    ),
    textTheme: TextTheme(
      headlineLarge: typo.sansBody.copyWith(
        fontSize: 34,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.1,
      ),
      headlineMedium: typo.sansBody.copyWith(
        fontSize: 28,
        height: 1.16,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
      ),
      titleLarge: typo.sansBody.copyWith(
        fontSize: 20,
        height: 1.22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.35,
      ),
      titleMedium: typo.sansBody.copyWith(
        fontSize: 17,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.25,
      ),
      bodyMedium: typo.sansBody,
      bodySmall: typo.sansBody.copyWith(
        fontSize: 13,
        height: 1.38,
        color: colors.muted2,
      ),
      labelLarge: typo.sansBody.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
      ),
      labelMedium: typo.sansBody.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colors.border.withValues(
        alpha: brightness == Brightness.dark ? 0.72 : 0.56,
      ),
      thickness: 0.5,
      space: 0.5,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.muted2,
      textColor: colors.text,
      titleTextStyle: typo.sansBody.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.2,
      ),
      subtitleTextStyle: typo.sansBody.copyWith(
        fontSize: 12.5,
        height: 1.35,
        color: colors.muted,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: colors.text,
        shape: const CircleBorder(),
        animationDuration: const Duration(milliseconds: 160),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 48),
        shape: const StadiumBorder(),
        textStyle: typo.sansBody.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        elevation: 0,
        animationDuration: const Duration(milliseconds: 180),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 46),
        shape: const StadiumBorder(),
        side: BorderSide(color: colors.border),
        backgroundColor: colors.glassFill,
        foregroundColor: colors.text,
        animationDuration: const Duration(milliseconds: 180),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: colors.accent,
        minimumSize: const Size(44, 44),
        shape: const StadiumBorder(),
        textStyle: typo.sansBody.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        animationDuration: const Duration(milliseconds: 160),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Colors.transparent,
      modalBarrierColor: const Color(0x66000000),
      shadowColor: colors.glassShadow,
      elevation: 0,
      modalElevation: 0,
      dragHandleColor: colors.muted.withValues(alpha: 0.42),
      dragHandleSize: const Size(36, 4),
      showDragHandle: false,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: typo.sansBody.copyWith(fontSize: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark
          ? colors.surface
          : colors.text,
      contentTextStyle: typo.sansBody.copyWith(
        color: brightness == Brightness.dark ? colors.text : colors.bg,
        fontSize: 14,
      ),
      actionTextColor: colors.accent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.onAccent
            : colors.surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.accent
            : colors.muted.withValues(alpha: 0.34),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Color(0x00000000)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.accent,
      linearTrackColor: colors.accent.withValues(alpha: 0.16),
      circularTrackColor: colors.accent.withValues(alpha: 0.16),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.glassFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: colors.border.withValues(alpha: 0.52),
          width: 0.5,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.accent, width: 1.4),
      ),
      hintStyle: typo.sansBody.copyWith(color: colors.muted, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
    ),
  );
}

/// Dark theme — the app's original look.
ThemeData buildDarkTheme() => _buildTheme(
  brightness: Brightness.dark,
  colors: AppColors.dark,
  typo: AppTypography.dark,
);

/// Light theme — derived palette (tune hexes in `app_colors.dart`).
ThemeData buildLightTheme() => _buildTheme(
  brightness: Brightness.light,
  colors: AppColors.light,
  typo: AppTypography.light,
);
