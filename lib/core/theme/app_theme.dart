import 'package:flutter/material.dart';

/// What:   FairBid brand and semantic colours outside Material's [ColorScheme] (DESIGN.md §1).
/// Input:  Built in [AppTheme]; read with `context.fairbid`.
/// Output: Theme extension of colour tokens.
@immutable
class FairBidColors extends ThemeExtension<FairBidColors> {
  const FairBidColors({
    required this.verified,
    required this.success,
    required this.warning,
    required this.danger,
    required this.subtleBlue,
    required this.borderSubtle,
    required this.warningText,
    required this.successText,
  });

  final Color verified; // #0052FF brand / verified
  final Color success; // #00C853
  final Color warning; // #FBBC04
  final Color danger; // #D32F2F
  final Color subtleBlue; // #F0F5FF stat-card / banner fill
  final Color borderSubtle; // #E2E8F0 hairline border
  final Color warningText; // #B07B00 dark amber icon/accent on tinted fills

  /// #087F3F dark green for text and glyphs on light fills; [success] fails AA as a foreground.
  final Color successText;

  @override
  FairBidColors copyWith({
    Color? verified,
    Color? success,
    Color? warning,
    Color? danger,
    Color? subtleBlue,
    Color? borderSubtle,
    Color? warningText,
    Color? successText,
  }) {
    return FairBidColors(
      verified: verified ?? this.verified,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      subtleBlue: subtleBlue ?? this.subtleBlue,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      warningText: warningText ?? this.warningText,
      successText: successText ?? this.successText,
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
      warningText: Color.lerp(warningText, other.warningText, t)!,
      successText: Color.lerp(successText, other.successText, t)!,
    );
  }

  static const light = FairBidColors(
    verified: Color(0xFF0052FF),
    success: Color(0xFF00C853),
    warning: Color(0xFFFBBC04),
    danger: Color(0xFFD32F2F),
    subtleBlue: Color(0xFFF0F5FF),
    borderSubtle: Color(0xFFE2E8F0),
    warningText: Color(0xFFB07B00),
    successText: Color(0xFF087F3F),
  );
}

/// What:   Shortcut to the FairBid colour extension.
/// Output: `context.fairbid` returns the FairBidColors of the current theme.
extension FairBidColorsX on BuildContext {
  FairBidColors get fairbid => Theme.of(this).extension<FairBidColors>()!;
}

/// What:   Builds the app's [ThemeData] from the DESIGN.md tokens.
/// Input:  None; [light] is built once.
/// Output: The light theme with the [FairBidColors] extension.
class AppTheme {
  const AppTheme._();

  static const brandBlue = Color(0xFF0052FF);

  /// Built once: a fresh ThemeData never compares equal (closure-based styles) and would re-theme the app.
  static final ThemeData light = _buildLight();

  /// What:   Assembles the light ThemeData.
  /// Output: ColorScheme, text, input, button and card themes plus the FairBidColors extension.
  static ThemeData _buildLight() {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: Color(0xFF003EC7),
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: brandBlue,
      onPrimaryContainer: Color(0xFFDFE3FF),
      secondary: Color(0xFF006E2A),
      onSecondary: Color(0xFFFFFFFF),
      // Material 3 paints the NavigationBar's selected pill and the selected
      // SegmentedButton segment from secondaryContainer, which falls back to
      // `secondary` when unset - so leaving these out rendered the selected
      // tab, the most persistent chrome in the app, in a dark green that
      // appears nowhere in the brand. A brand-blue tint at 5.3:1 instead.
      secondaryContainer: Color(0xFFF0F5FF),
      onSecondaryContainer: brandBlue,
      tertiary: Color(0xFF654900),
      onTertiary: Color(0xFFFFFFFF),
      error: Color(0xFFBA1A1A),
      onError: Color(0xFFFFFFFF),
      surface: Color(0xFFF7F9FB),
      // Cards must stand out from the F7F9FB scaffold background, so this is
      // literal white rather than surface's own tint.
      surfaceContainerLowest: Colors.white,
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
          // A minimum *width* here (not `Size.fromHeight`, which is an
          // infinite-width minimum) used to force every bare FilledButton
          // full width, including the two side by side in a dialog's
          // `actions` - stacking them oddly instead of sizing to their
          // label. Pages that want a full-width button use [PrimaryButton],
          // which applies its own full-width wrapper.
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: brandBlue,
          // `styleFrom`'s own `disabledForegroundColor` only covers the
          // label/icon - its `side` stays a plain, always-blue BorderSide, so
          // a disabled OutlinedButton kept its enabled-looking outline. A
          // state-aware `side` (via copyWith, below) is needed to grey it out
          // too.
          disabledForegroundColor: colorScheme.onSurface.withValues(alpha: 0.38),
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.disabled)
                  ? colorScheme.onSurface.withValues(alpha: 0.12)
                  : brandBlue,
            ),
          ),
        ),
      ),
    );
  }

  /// What:   DESIGN.md §2 typography.
  /// Input:  [base] text theme.
  /// Output: [base] with sizes, weights and spacing overridden.
  /// Notes:  Uses copyWith on the base styles; a fresh TextStyle loses the resolved colour and typed input turns invisible.
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

  /// What:   Text-field look: white fill, rounded outline, blue focus border, error border from [scheme].
  /// Output: InputDecorationTheme.
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
