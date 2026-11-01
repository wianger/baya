import 'package:flutter/material.dart';

/// Semantic color tokens for the whole app.
///
/// This is the SINGLE source of truth for every color used in the UI. Widgets
/// must never hardcode `Color(0x…)` or `Colors.*` — they read from here via
/// `context.colors.<token>` (see `theme_extensions.dart`).
///
/// Registered on [ThemeData.extensions] by `buildDarkTheme()` /
/// `buildLightTheme()` so `Theme.of(context).extension<AppColors>()` resolves
/// the right palette for the active brightness.
///
/// Apple-inspired semantic palette. Brightness variants use system-style
/// grouped backgrounds, neutral labels, system blue, and restrained status
/// colors while keeping every screen within the same token set.
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

  /// App background (scaffold). Was `kBg`.
  final Color bg;

  /// Slightly raised surface (cards, sheets). Was `kSurface`.
  final Color surface;

  /// Hairline borders / dividers. Was `kBorder`.
  final Color border;

  /// Primary foreground text. Was `kText`.
  final Color text;

  /// Secondary / de-emphasized text. Was `kMuted`.
  final Color muted;

  /// Tertiary text — slightly more prominent than [muted]. Was `kMuted2`.
  final Color muted2;

  /// Brand accent (links, active states, primary buttons). Was `kAccent`.
  final Color accent;

  /// Foreground painted on top of [accent] (e.g. filled-button label). Was the
  /// hardcoded `Colors.black` / `onPrimary`.
  final Color onAccent;

  /// Code / file paths inside agent messages. Was `kHighlight`.
  final Color highlight;

  /// Success state (✓ tool results). Was `kSuccess`.
  final Color success;

  /// Error / destructive state (✗ tool results, failed sends, delete). Was
  /// `kError` and the scattered `Colors.redAccent`.
  final Color error;

  /// Warning state (relay offline). Was the scattered `Colors.amber`.
  final Color warning;

  /// "Working" / in-progress accent (session running a turn). Was the local
  /// `kWorking = Color(0xFF3FA9F5)` duplicated in session_tile and chat_page.
  final Color working;

  /// Background of inline/he block code. Was `kCodeBg`.
  final Color codeBg;

  /// User chat bubble background. Was `kUserBubble`.
  final Color userBubble;

  /// Foreground painted on the user bubble.
  final Color onUserBubble;

  /// Model badge background. Was `kModelBadgeBg`.
  final Color modelBadgeBg;

  /// Model badge border. Was `kModelBadgeBorder`.
  final Color modelBadgeBorder;

  /// Border for a denied tool-call card. Was `kDenyBorder`.
  final Color denyBorder;

  /// Text-field fill. Was the hardcoded `Color(0xFF0E0E0E)`.
  final Color inputFill;

  // Layered Apple-style materials. Text always renders above these translucent
  // fills; high-contrast surfaces opt out of translucency in
  // BayaGlassSurface.
  bool get _isDark => bg.computeLuminance() < 0.2;
  //
  // These are fully opaque pigments. BayaGlassSurface applies the final alpha
  // once, per material role. Keeping alpha out of the pigment avoids the
  // compounded, muddy layers that made earlier glass look like gray plastic.
  Color get glassFill =>
      _isDark ? const Color(0xFF68717D) : const Color(0xFFFFFFFF);
  Color get glassFillStrong =>
      _isDark ? const Color(0xFF89929E) : const Color(0xFFFFFFFF);
  Color get glassTint =>
      _isDark ? const Color(0xFF171A20) : const Color(0xFFF4F7FA);
  Color get glassEdge =>
      const Color(0xFFFFFFFF).withValues(alpha: _isDark ? 0.20 : 0.70);
  Color get glassShade =>
      const Color(0xFF000000).withValues(alpha: _isDark ? 0.32 : 0.11);
  Color get glassHighlight =>
      const Color(0xFFFFFFFF).withValues(alpha: _isDark ? 0.16 : 0.72);
  Color get glassShadow =>
      const Color(0xFF000000).withValues(alpha: _isDark ? 0.30 : 0.10);
  Color get glassContactShadow =>
      const Color(0xFF000000).withValues(alpha: _isDark ? 0.12 : 0.035);
  Color get glassInnerShadow =>
      const Color(0xFF000000).withValues(alpha: _isDark ? 0.10 : 0.025);
  Color get glassCool => _isDark
      ? const Color(0xFF586D8A).withValues(alpha: 0.14)
      : const Color(0xFFC9DBF2).withValues(alpha: 0.24);
  Color get glassWarm => _isDark
      ? const Color(0xFF8F7566).withValues(alpha: 0.09)
      : const Color(0xFFF0DECB).withValues(alpha: 0.17);
  Color get selection => accent.withValues(alpha: _isDark ? 0.13 : 0.085);
  Color get quietFill => surface.withValues(alpha: _isDark ? 0.72 : 0.84);
  Color get backdropAccent =>
      const Color(0xFF5E70A0).withValues(alpha: _isDark ? 0.11 : 0.18);
  Color get backdropWarmth => glassWarm;

  /// True-black canvas with elevated graphite groups.
  static const AppColors dark = AppColors(
    bg: Color(0xFF0B0C0F),
    surface: Color(0xFF202228),
    border: Color(0xFF45474E),
    text: Color(0xFFF5F5F7),
    muted: Color(0xFF98989F),
    muted2: Color(0xFFC7C7CC),
    accent: Color(0xFF0A84FF),
    onAccent: Color(0xFFFFFFFF),
    highlight: Color(0xFF64D2FF),
    success: Color(0xFF30D158),
    error: Color(0xFFFF453A),
    warning: Color(0xFFFF9F0A),
    working: Color(0xFF64D2FF),
    codeBg: Color(0xFF17191E),
    userBubble: Color(0xFF0A84FF),
    onUserBubble: Color(0xFFFFFFFF),
    modelBadgeBg: Color(0xFF2B2D33),
    modelBadgeBorder: Color(0xFF4B4E55),
    denyBorder: Color(0x66FF453A),
    inputFill: Color(0xFF202228),
  );

  /// Grouped iOS canvas with white control surfaces.
  static const AppColors light = AppColors(
    bg: Color(0xFFF2F2F7),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFD1D1D6),
    text: Color(0xFF1D1D1F),
    muted: Color(0xFF8E8E93),
    muted2: Color(0xFF636366),
    accent: Color(0xFF007AFF),
    onAccent: Color(0xFFFFFFFF),
    highlight: Color(0xFF007AFF),
    success: Color(0xFF34C759),
    error: Color(0xFFFF3B30),
    warning: Color(0xFFFF9500),
    working: Color(0xFF5AC8FA),
    codeBg: Color(0xFFF2F2F7),
    userBubble: Color(0xFF007AFF),
    onUserBubble: Color(0xFFFFFFFF),
    modelBadgeBg: Color(0xFFE5E5EA),
    modelBadgeBorder: Color(0xFFD1D1D6),
    denyBorder: Color(0x66FF3B30),
    inputFill: Color(0xFFFFFFFF),
  );

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
