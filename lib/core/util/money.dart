import 'package:intl/intl.dart';

/// Money in FairBid is stored as an integer number of **sen** (1/100 RM) to
/// avoid floating-point rounding. These helpers format sen for display.
final _rm = NumberFormat('#,##0.00');

/// Formats sen as `RM 1,234.50`.
String formatRm(int sen) => 'RM ${_rm.format(sen / 100)}';

/// Formats a budget range: `RM 100`, `RM 100 – RM 250`, with an optional
/// `/hr` suffix. Returns `null` when neither bound is set.
String? formatBudget({int? minSen, int? maxSen, bool hourly = false}) {
  if (minSen == null && maxSen == null) return null;
  final suffix = hourly ? '/hr' : '';
  if (minSen != null && maxSen != null && minSen != maxSen) {
    return '${formatRm(minSen)} – ${formatRm(maxSen)}$suffix';
  }
  return '${formatRm(minSen ?? maxSen!)}$suffix';
}

/// Parses a user-typed RM amount (e.g. "125.50") into sen, or null if blank.
int? parseRmToSen(String? input) {
  final text = input?.trim() ?? '';
  if (text.isEmpty) return null;
  final value = double.tryParse(text.replaceAll(',', ''));
  if (value == null) return null;
  return (value * 100).round();
}
