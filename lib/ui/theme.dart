import 'package:flutter/material.dart';

/// Warm, quiet palette: an orange accent on paper in light mode, on charcoal in dark mode.
/// Direction badges keep the old dashboard's meanings (green rising, amber peaking, grey fading).
class SbColors extends ThemeExtension<SbColors> {
  const SbColors({required this.rising, required this.risingBg, required this.peaking, required this.peakingBg, required this.fading, required this.fadingBg, required this.star, required this.panel, required this.line, required this.muted, required this.faint});
  final Color rising, risingBg, peaking, peakingBg, fading, fadingBg, star, panel, line, muted, faint;

  static const light = SbColors(
    rising: Color(0xFF2F7D4F), risingBg: Color(0xFFE8F4EC),
    peaking: Color(0xFF9A6B12), peakingBg: Color(0xFFFBF2DF),
    fading: Color(0xFF8A8580), fadingBg: Color(0xFFF0EEEB),
    star: Color(0xFFD4A017), panel: Colors.white, line: Color(0xFFE5E1DA), muted: Color(0xFF78716A), faint: Color(0xFFA8A29A),
  );
  static const dark = SbColors(
    rising: Color(0xFF6CC48C), risingBg: Color(0xFF16301F),
    peaking: Color(0xFFD4A955), peakingBg: Color(0xFF2E2515),
    fading: Color(0xFF7D7889), fadingBg: Color(0xFF26242C),
    star: Color(0xFFE8C15A), panel: Color(0xFF1E1D23), line: Color(0xFF302E37), muted: Color(0xFF9B96A5), faint: Color(0xFF6D6878),
  );

  @override
  SbColors copyWith() => this;
  @override
  SbColors lerp(SbColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final accent = dark ? const Color(0xFFE8874A) : const Color(0xFFB4531F);
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: b, primary: accent, surface: dark ? const Color(0xFF16151A) : const Color(0xFFFAF9F7));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    fontFamily: null,
    textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 14, height: 1.4)),
    dividerColor: dark ? SbColors.dark.line : SbColors.light.line,
    extensions: [dark ? SbColors.dark : SbColors.light],
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: dark ? SbColors.dark.panel : SbColors.light.panel,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: dark ? SbColors.dark.line : SbColors.light.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(9), borderSide: BorderSide(color: dark ? SbColors.dark.line : SbColors.light.line)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );
}

extension SbTheme on BuildContext {
  SbColors get sb => Theme.of(this).extension<SbColors>()!;
}
