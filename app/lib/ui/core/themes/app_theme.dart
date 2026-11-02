import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';

import 'package:app/ui/core/themes/app_colors.dart';
import 'package:app/ui/core/themes/app_typography.dart';

/// Material 3 theme from one [ColorScheme]. Framework widgets use the scheme
/// directly; app widgets read the same palette through [AppColors] and
/// [AppTypography] extensions.
ThemeData _buildTheme(ColorScheme scheme) {
  final colors = AppColors.fromScheme(scheme);
  final typo = AppTypography.fromColors(colors, monoColor: colors.text);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.bg,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    extensions: <ThemeExtension<dynamic>>[colors, typo],
    // Predictive back: the previous page peeks in while the gesture runs.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.bg,
      foregroundColor: colors.text,
      scrolledUnderElevation: 3,
      surfaceTintColor: scheme.surfaceTint,
      toolbarHeight: 64,
    ),
    dividerTheme: DividerThemeData(
      color: colors.border,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.muted,
      subtitleTextStyle: typo.sansBody.copyWith(
        fontSize: 13,
        color: colors.muted,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(44, 48))),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(44, 48))),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(44, 44))),
    ),
    // Sheets, dialogs and menus paint their own BayaSurface.
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: false,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.inputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.accent, width: 2),
      ),
      hintStyle: typo.sansBody.copyWith(color: colors.muted, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
  );
}

/// Light theme from the wallpaper palette, or the brand seed without one.
ThemeData buildLightTheme([ColorScheme? dynamic]) => _buildTheme(
  dynamic?.harmonized() ?? AppColors.fallbackScheme(Brightness.light),
);

/// Dark theme from the wallpaper palette, or the brand seed without one.
ThemeData buildDarkTheme([ColorScheme? dynamic]) => _buildTheme(
  dynamic?.harmonized() ?? AppColors.fallbackScheme(Brightness.dark),
);
