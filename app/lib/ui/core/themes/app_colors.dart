import 'package:flutter/material.dart';

/// Baya's palette: graphite and paper neutrals with one straw-gold accent,
/// taken from the woven-nest mark. The palette is the brand's own (it does
/// not follow the wallpaper), so every screen reads as one product.
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

  /// Graphite: the default.
  static const dark = AppColors(
    bg: Color(0xFF0E0E10),
    surface: Color(0xFF161618),
    border: Color(0xFF26262A),
    text: Color(0xFFEDEDEF),
    muted: Color(0xFF8A8A93),
    muted2: Color(0xFFB8B8BF),
    accent: Color(0xFFF2CF7E),
    onAccent: Color(0xFF1C1405),
    highlight: Color(0xFFE9C27A),
    success: Color(0xFF5CD69B),
    error: Color(0xFFFF6B6B),
    warning: Color(0xFFF5B94A),
    working: Color(0xFFF2CF7E),
    codeBg: Color(0xFF121214),
    userBubble: Color(0xFF222226),
    onUserBubble: Color(0xFFEDEDEF),
    modelBadgeBg: Color(0xFF1E1E22),
    modelBadgeBorder: Color(0xFF2E2E33),
    denyBorder: Color(0x66FF6B6B),
    inputFill: Color(0xFF1B1B1E),
  );

  /// Paper.
  static const light = AppColors(
    bg: Color(0xFFFAF9F6),
    surface: Color(0xFFF3F1EC),
    border: Color(0xFFE3E0D8),
    text: Color(0xFF17171A),
    muted: Color(0xFF6E6C66),
    muted2: Color(0xFF45433E),
    accent: Color(0xFFA9711A),
    onAccent: Color(0xFFFFFFFF),
    highlight: Color(0xFF8E5A10),
    success: Color(0xFF1B8A55),
    error: Color(0xFFC93A32),
    warning: Color(0xFF9C6205),
    working: Color(0xFFA9711A),
    codeBg: Color(0xFFF1EEE7),
    userBubble: Color(0xFFECE9E2),
    onUserBubble: Color(0xFF17171A),
    modelBadgeBg: Color(0xFFEDEAE3),
    modelBadgeBorder: Color(0xFFDDD9CF),
    denyBorder: Color(0x66C93A32),
    inputFill: Color(0xFFF0EDE6),
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
  Color get selection => accent.withValues(alpha: .12);

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
  static const ink = Color(0xFF141416);
  static const tile = Color(0xFFF3F1EC);
}
