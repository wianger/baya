import 'package:flutter/material.dart';

/// Baya's palette: black and white. Ink on paper by day, paper on ink
/// (true black, kind to OLED) by night, with greys between; no hue anywhere
/// but red, kept for what fails or is destroyed. The palette is the brand's
/// own (it does not follow the wallpaper), so every screen reads as one
/// product.
///
/// Widgets read `context.colors.<token>` and never hardcode colors.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.border,
    required this.text,
    required this.muted,
    required this.muted2,
    required this.accent,
    required this.onAccent,
    required this.highlight,
    required this.success,
    required this.error,
    required this.warning,
    required this.working,
    required this.codeBg,
    required this.userBubble,
    required this.onUserBubble,
    required this.modelBadgeBg,
    required this.modelBadgeBorder,
    required this.denyBorder,
    required this.inputFill,
  });

  /// Ink: the default.
  static const dark = AppColors(
    bg: Color(0xFF000000),
    surface: Color(0xFF0E0E0E),
    border: Color(0xFF242424),
    text: Color(0xFFF5F5F5),
    muted: Color(0xFF8E8E8E),
    muted2: Color(0xFFBDBDBD),
    accent: Color(0xFFFFFFFF),
    onAccent: Color(0xFF000000),
    highlight: Color(0xFFE6E6E6),
    success: Color(0xFFDADADA),
    error: Color(0xFFFF5A52),
    warning: Color(0xFFC9C9C9),
    working: Color(0xFFFFFFFF),
    codeBg: Color(0xFF0B0B0B),
    userBubble: Color(0xFF1C1C1C),
    onUserBubble: Color(0xFFF5F5F5),
    modelBadgeBg: Color(0xFF151515),
    modelBadgeBorder: Color(0xFF2A2A2A),
    denyBorder: Color(0x66FF5A52),
    inputFill: Color(0xFF161616),
  );

  /// Paper. Text colours meet WCAG AA (4.5:1) on every light surface.
  static const light = AppColors(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF6F6F6),
    border: Color(0xFFE5E5E5),
    text: Color(0xFF0A0A0A),
    muted: Color(0xFF5F5F5F),
    muted2: Color(0xFF383838),
    accent: Color(0xFF000000),
    onAccent: Color(0xFFFFFFFF),
    highlight: Color(0xFF1A1A1A),
    success: Color(0xFF2E2E2E),
    error: Color(0xFFC62A22),
    warning: Color(0xFF474747),
    working: Color(0xFF000000),
    codeBg: Color(0xFFF5F5F5),
    userBubble: Color(0xFFF0F0F0),
    onUserBubble: Color(0xFF0A0A0A),
    modelBadgeBg: Color(0xFFF2F2F2),
    modelBadgeBorder: Color(0xFFE0E0E0),
    denyBorder: Color(0x66C62A22),
    inputFill: Color(0xFFF3F3F3),
  );

  /// The Material scheme framework widgets read, from the same tokens.
  ColorScheme scheme(Brightness brightness) => ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: userBubble,
    onPrimaryContainer: onUserBubble,
    secondary: muted2,
    onSecondary: bg,
    secondaryContainer: inputFill,
    onSecondaryContainer: text,
    tertiary: working,
    onTertiary: onAccent,
    error: error,
    onError: bg,
    surface: bg,
    onSurface: text,
    onSurfaceVariant: muted,
    surfaceContainerLowest: bg,
    surfaceContainerLow: surface,
    surfaceContainer: codeBg,
    surfaceContainerHigh: inputFill,
    surfaceContainerHighest: modelBadgeBg,
    outline: muted,
    outlineVariant: border,
    inverseSurface: text,
    onInverseSurface: bg,
    surfaceTint: Colors.transparent,
  );

  final Color bg; // surface
  final Color surface; // surfaceContainerLow: cards, grouped content
  final Color border; // outlineVariant
  final Color text; // onSurface
  final Color muted; // onSurfaceVariant
  final Color muted2; // between muted and text
  final Color accent; // primary
  final Color onAccent; // onPrimary
  final Color highlight; // tertiary: code and paths in agent text
  final Color success;
  final Color error;
  final Color warning;
  final Color working; // tertiary: a session running a turn
  final Color codeBg; // surfaceContainer
  final Color userBubble; // primaryContainer
  final Color onUserBubble; // onPrimaryContainer
  final Color modelBadgeBg; // surfaceContainerHighest
  final Color modelBadgeBorder;
  final Color denyBorder;
  final Color inputFill; // surfaceContainerHigh: fields and controls

  /// Tonal layers. Material 3 expresses elevation through tone, not
  /// translucency or heavy shadows.
  Color get glassFill => inputFill;
  Color get selection => accent.withValues(alpha: .10);

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? border,
    Color? text,
    Color? muted,
    Color? muted2,
    Color? accent,
    Color? onAccent,
    Color? highlight,
    Color? success,
    Color? error,
    Color? warning,
    Color? working,
    Color? codeBg,
    Color? userBubble,
    Color? onUserBubble,
    Color? modelBadgeBg,
    Color? modelBadgeBorder,
    Color? denyBorder,
    Color? inputFill,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      border: border ?? this.border,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      muted2: muted2 ?? this.muted2,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      highlight: highlight ?? this.highlight,
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
      working: working ?? this.working,
      codeBg: codeBg ?? this.codeBg,
      userBubble: userBubble ?? this.userBubble,
      onUserBubble: onUserBubble ?? this.onUserBubble,
      modelBadgeBg: modelBadgeBg ?? this.modelBadgeBg,
      modelBadgeBorder: modelBadgeBorder ?? this.modelBadgeBorder,
      denyBorder: denyBorder ?? this.denyBorder,
      inputFill: inputFill ?? this.inputFill,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      muted2: Color.lerp(muted2, other.muted2, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      working: Color.lerp(working, other.working, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      onUserBubble: Color.lerp(onUserBubble, other.onUserBubble, t)!,
      modelBadgeBg: Color.lerp(modelBadgeBg, other.modelBadgeBg, t)!,
      modelBadgeBorder: Color.lerp(
        modelBadgeBorder,
        other.modelBadgeBorder,
        t,
      )!,
      denyBorder: Color.lerp(denyBorder, other.denyBorder, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
    );
  }
}

/// The mark's colors, the same as branding/baya-mark.svg.
abstract final class AppBrandColors {
  static const ink = Color(0xFF141414);
  static const paper = Color(0xFFFFFFFF);
}
