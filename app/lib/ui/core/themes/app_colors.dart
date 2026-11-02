import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

/// Semantic color tokens for the whole app, derived from one Material 3
/// [ColorScheme].
///
/// On Android 12+ the scheme comes from the wallpaper (Material You); other
/// devices use the brand seed. Widgets read `context.colors.<token>` and never
/// hardcode colors, so the whole app follows the system palette.
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

  /// Maps the M3 tonal roles onto the app's semantic tokens. Status colors
  /// have no M3 role, so fixed hues are harmonized toward the primary color.
  factory AppColors.fromScheme(ColorScheme s) {
    final dark = s.brightness == Brightness.dark;
    Color status(int argb) => Color(argb).harmonizeWith(s.primary);
    return AppColors(
      bg: s.surface,
      surface: s.surfaceContainerLow,
      border: s.outlineVariant,
      text: s.onSurface,
      muted: s.onSurfaceVariant,
      muted2: Color.lerp(s.onSurfaceVariant, s.onSurface, .45)!,
      accent: s.primary,
      onAccent: s.onPrimary,
      highlight: s.tertiary,
      success: status(dark ? 0xFF7DD99A : 0xFF1E7A43),
      error: s.error,
      warning: status(dark ? 0xFFF2B866 : 0xFF8C5A00),
      working: s.tertiary,
      codeBg: s.surfaceContainer,
      userBubble: s.primaryContainer,
      onUserBubble: s.onPrimaryContainer,
      modelBadgeBg: s.surfaceContainerHighest,
      modelBadgeBorder: s.outlineVariant,
      denyBorder: s.error.withValues(alpha: .4),
      inputFill: s.surfaceContainerHigh,
    );
  }

  /// Brand seed for devices without a wallpaper palette.
  static const seed = Color(0xFF2F6F73);

  static ColorScheme fallbackScheme(Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

  static final AppColors light = AppColors.fromScheme(
    fallbackScheme(Brightness.light),
  );
  static final AppColors dark = AppColors.fromScheme(
    fallbackScheme(Brightness.dark),
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
  Color get glassFillStrong => modelBadgeBg;
  Color get glassShadow => const Color(0x1F000000);
  Color get selection => accent.withValues(alpha: .12);
  Color get quietFill => surface;

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

/// Fixed launcher/brand tile colors, shared by light and dark presentations.
abstract final class AppBrandColors {
  /// Sculptural treatment: a softly lit ivory tile, a graphite-teal bird and
  /// one restrained gold accent. Values match baya-mark.svg.
  static const background = Color(0xFFFFFFFF);
  static const backgroundLight = Color(0xFFFFFFFF);
  static const backgroundDeep = Color(0xFFF4F0E7);
  static const edge = Color(0xFFE8E3D9);
  static const foreground = Color(0xFF18222B);
  static const foregroundLight = Color(0xFF3C5358);
  static const foregroundShade = Color(0xFF121920);
  static const highlight = Color(0xFFC7933F);
  static const highlightLight = Color(0xFFD8AE6A);
  static const highlightDeep = Color(0xFF8C6326);
  static const reflection = Color(0xFFFFFFFF);
  static const shadow = Color(0xFF12151C);
}
