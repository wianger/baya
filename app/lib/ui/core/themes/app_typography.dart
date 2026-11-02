import 'package:flutter/material.dart';

import 'package:app/ui/core/themes/app_colors.dart';

/// Bundled OFL fonts stay in place for consistent Latin rendering across
/// Android devices. CJK continues to use the device's native sans face.
const String kSansFamily = 'Geist';
const String kMonoFamily = 'Geist Mono';
const String kWordmarkFamily = 'Pinyon Script';

/// CJK and other scripts use the device's installed sans fonts.
const List<String> kFontFallback = [
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'sans-serif',
];

/// General branded labels use the bundled interface face.
TextStyle brandTextStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w700,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontFamily: kSansFamily,
    fontFamilyFallback: kFontFallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// Display face for the app wordmark. Pinyon Script is an OFL-licensed formal
/// script bundled for the Baya signature.
TextStyle brandDisplayTextStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w400,
  Color? color,
}) {
  return TextStyle(
    fontFamily: kWordmarkFamily,
    fontFamilyFallback: kFontFallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: .2,
    height: 1.2,
  );
}

/// Typographic styles for the app, themed per brightness (colors baked in so
/// the common case — `context.typo.mono` — is correct without a `.copyWith`).
///
/// This is the SINGLE source of truth for text styles. Widgets read
/// `context.typo.<style>` and `.copyWith(...)` only for one-off size/weight
/// tweaks — never re-declaring `fontFamily`.
///
/// Registered on [ThemeData.extensions]; resolve via
/// `Theme.of(context).extension<AppTypography>()`.
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.mono,
    required this.monoSmall,
    required this.sansBody,
  });

  /// Primary monospace style (chat code, terminal chrome). Was `kMonoStyle`.
  final TextStyle mono;

  /// Small monospace style for paths and compact technical values.
  final TextStyle monoSmall;

  /// Sans body text. Was `kSansBody`.
  final TextStyle sansBody;

  /// Long responses: the sans face with a looser reading rhythm.
  TextStyle get reading => sansBody.copyWith(
    fontFamily: kSansFamily,
    fontFamilyFallback: kFontFallback,
    fontSize: 16,
    height: 1.58,
    letterSpacing: -0.15,
  );

  TextStyle get title => sansBody.copyWith(
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
  );

  /// Build the style set for a given color palette so text colors track the
  /// active theme. [monoColor] is the resting mono text color (was the
  /// hardcoded `0xFFE6E6E6` in dark).
  factory AppTypography.fromColors(AppColors c, {required Color monoColor}) {
    return AppTypography(
      mono: TextStyle(
        fontFamily: kMonoFamily,
        fontFamilyFallback: kFontFallback,
        fontSize: 12.5,
        color: monoColor,
        height: 1.5,
        letterSpacing: 0,
      ),
      monoSmall: TextStyle(
        fontFamily: kMonoFamily,
        fontFamilyFallback: kFontFallback,
        fontSize: 12.0,
        color: c.muted2,
        height: 1.4,
      ),
      sansBody: TextStyle(
        fontFamily: kSansFamily,
        fontFamilyFallback: kFontFallback,
        fontSize: 16.0,
        color: c.text,
        height: 1.47,
        letterSpacing: -0.18,
      ),
    );
  }

  /// Dark typography — mono text matches the original `0xFFE6E6E6`.
  static final AppTypography dark = AppTypography.fromColors(
    AppColors.dark,
    monoColor: const Color(0xFFE6E6E6),
  );

  /// Light typography — mono text is a near-black for contrast on white.
  static final AppTypography light = AppTypography.fromColors(
    AppColors.light,
    monoColor: const Color(0xFF1A1A1A),
  );

  @override
  AppTypography copyWith({
    TextStyle? mono,
    TextStyle? monoSmall,
    TextStyle? sansBody,
  }) {
    return AppTypography(
      mono: mono ?? this.mono,
      monoSmall: monoSmall ?? this.monoSmall,
      sansBody: sansBody ?? this.sansBody,
    );
  }

  @override
  AppTypography lerp(ThemeExtension<AppTypography>? other, double t) {
    if (other is! AppTypography) return this;
    return AppTypography(
      mono: TextStyle.lerp(mono, other.mono, t)!,
      monoSmall: TextStyle.lerp(monoSmall, other.monoSmall, t)!,
      sansBody: TextStyle.lerp(sansBody, other.sansBody, t)!,
    );
  }
}
