import 'package:flutter/material.dart';

/// FairBid brand and semantic colours that are not part of Material's
/// [ColorScheme]. Read them with `Theme.of(context).extension<FairBidColors>()`.
///
/// Values come from DESIGN.md (§1 Colour tokens).
@immutable
class FairBidColors extends ThemeExtension<FairBidColors> {
  const FairBidColors({
    required this.verified,
    required this.success,
    required this.warning,
    required this.danger,
    required this.subtleBlue,
    required this.borderSubtle,
  });

  final Color verified; // #0052FF brand / verified
  final Color success; // #00C853
  final Color warning; // #FBBC04
  final Color danger; // #D32F2F
  final Color subtleBlue; // #F0F5FF stat-card / banner fill
  final Color borderSubtle; // #E2E8F0 hairline border

  @override
  FairBidColors copyWith({
    Color? verified,
    Color? success,
    Color? warning,
    Color? danger,
    Color? subtleBlue,
    Color? borderSubtle,
  }) {
    return FairBidColors(
      verified: verified ?? this.verified,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      subtleBlue: subtleBlue ?? this.subtleBlue,
      borderSubtle: borderSubtle ?? this.borderSubtle,
    );
  }

  @override
  FairBidColors lerp(FairBidColors? other, double t) {
    if (other == null) return this;
    return FairBidColors(
      verified: Color.lerp(verified, other.verified, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      subtleBlue: Color.lerp(subtleBlue, other.subtleBlue, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
    );
  }

  static const light = FairBidColors(
    verified: Color(0xFF0052FF),
    success: Color(0xFF00C853),
    warning: Color(0xFFFBBC04),
    danger: Color(0xFFD32F2F),
    subtleBlue: Color(0xFFF0F5FF),
    borderSubtle: Color(0xFFE2E8F0),
  );
}

/// Convenience accessor: `context.fairbid.verified` etc.
extension FairBidColorsX on BuildContext {
  FairBidColors get fairbid => Theme.of(this).extension<FairBidColors>()!;
}

/// Central place to build the app's [ThemeData] from the DESIGN.md tokens.
class AppTheme {
  const AppTheme._();

  static const brandBlue = Color(0xFF0052FF);

  static ThemeData get light {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF003EC7),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: brandBlue,
      onPrimaryContainer: Color(0xFFDFE3FF),
      secondary: Color(0xFF006E2A),
      onSecondary: Color(0xFFFFFFFF),
      tertiary: Color(0xFF654900),
      onTertiary: Color(0xFFFFFFFF),
      error: Color(0xFFBA1A1A),
      onError: Color(0xFFFFFFFF),
      surface: Color(0xFFF7F9FB),
      onSurface: Color(0xFF191C1E),
      onSurfaceVariant: Color(0xFF434656),
      outline: Color(0xFF737688),
      outlineVariant: Color(0xFFC3C5D9),
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      fontFamily: 'Roboto', // Inter can be added as an asset font later.
      extensions: const [FairBidColors.light],
    );

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      inputDecorationTheme: _inputTheme(colorScheme),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: brandBlue,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: const IconThemeData(color: Color(0xFF191C1E)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brandBlue,
          foregroundColor: Colors.white,
          disabledBackgroundColor: brandBlue.withValues(alpha: 0.35),
          disabledForegroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: brandBlue,
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: brandBlue),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  // Typography scale from DESIGN.md §2 (mapped onto Material's TextTheme slots).
  //
  // Use copyWith on the base styles (never a fresh `TextStyle`) so the text
  // colours Flutter already resolved from the colorScheme are preserved — a
  // colourless override makes typed input render invisible on white fields.
  static TextTheme _textTheme(TextTheme base) {
    return base.copyWith(
      headlineMedium: base.headlineMedium?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 32 / 24,
        letterSpacing: -0.24,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 28 / 20,
      ),
      bodyLarge: base.bodyLarge?.copyWith(fontSize: 16, height: 24 / 16),
      bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 20 / 14),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.14,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    );
  }

  static InputDecorationTheme _inputTheme(ColorScheme scheme) {
    OutlineInputBorder border(Color color, [double width = 1]) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    return InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      enabledBorder: border(const Color(0xFFE2E8F0)),
      border: border(const Color(0xFFE2E8F0)),
      focusedBorder: border(brandBlue, 2),
      errorBorder: border(scheme.error),
      focusedErrorBorder: border(scheme.error, 2),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }
}
