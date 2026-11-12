import 'package:app/ui/core/themes/app_colors.dart';
import 'package:app/ui/core/themes/app_typography.dart';
import 'package:flutter/material.dart';

/// The theme from Baya's palette. Framework widgets read the derived
/// [ColorScheme]; app widgets read [AppColors] and [AppTypography].
ThemeData _buildTheme(AppColors colors, Brightness brightness) {
  final scheme = colors.scheme(brightness);
  final typo = AppTypography.fromColors(colors, monoColor: colors.text);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: kSansFamily,
    scaffoldBackgroundColor: colors.bg,
    splashFactory: InkSparkle.splashFactory,
    highlightColor: Colors.transparent,
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
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: 64,
      titleTextStyle: typo.title.copyWith(fontSize: 18),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    // Buttons: compact pills; primary is ink on paper (text on the
    // inverse surface), the accent stays for state and brand moments.
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.inputFill
              : colors.text,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? colors.muted : colors.bg,
        ),
        textStyle: WidgetStatePropertyAll(
          typo.sansBody.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        foregroundColor: WidgetStatePropertyAll(colors.text),
        side: WidgetStatePropertyAll(BorderSide(color: colors.border)),
        textStyle: WidgetStatePropertyAll(
          typo.sansBody.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        foregroundColor: WidgetStatePropertyAll(colors.text),
        textStyle: WidgetStatePropertyAll(
          typo.sansBody.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
    ),
    // Choices: the picked segment or chip is ink, like the primary button,
    // so it never blends into the surface behind it.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.text
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? colors.bg : colors.muted2,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? colors.text
                : colors.border,
          ),
        ),
        textStyle: WidgetStatePropertyAll(
          typo.sansBody.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: colors.text,
      checkmarkColor: colors.bg,
      side: BorderSide(color: colors.border),
      // A selected chip is filled with ink, so its label turns to paper.
      labelStyle: typo.sansBody.copyWith(
        fontSize: 14,
        color: WidgetStateColor.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? colors.bg : colors.text,
        ),
      ),
      secondaryLabelStyle: typo.sansBody.copyWith(
        fontSize: 14,
        color: colors.bg,
        fontWeight: FontWeight.w600,
      ),
      shape: const StadiumBorder(),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.onAccent
            : colors.muted2,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.accent
            : colors.inputFill,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.accent),
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
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.muted, width: 1.2),
      ),
      hintStyle: typo.sansBody.copyWith(color: colors.muted, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
  );
}

/// Paper.
ThemeData buildLightTheme() => _buildTheme(AppColors.light, Brightness.light);

/// Graphite.
ThemeData buildDarkTheme() => _buildTheme(AppColors.dark, Brightness.dark);
