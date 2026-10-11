import 'package:intl/intl.dart';

// Money is stored as integer sen (1/100 RM) to avoid float rounding; these helpers format it.
final _rm = NumberFormat('#,##0.00');

final _count = NumberFormat('#,##0');

/// Formats a count with thousands separators: `12,345`.
String formatCount(int n) => _count.format(n);

/// Formats sen as `RM 1,234.50` (non-breaking space keeps it on one line).
String formatRm(int sen) => 'RM\u00A0${_rm.format(sen / 100)}';

/// Formats a budget: `RM 100` or `RM 100 – RM 250`, with an optional `/hr`; null when neither bound is set.
String? formatBudget({int? minSen, int? maxSen, bool hourly = false}) {
  if (minSen == null && maxSen == null) return null;
  final suffix = hourly ? '/hr' : '';
  if (minSen != null && maxSen != null && minSen != maxSen) {
    return '${formatRm(minSen)} – ${formatRm(maxSen)}$suffix';
  }
  return '${formatRm(minSen ?? maxSen!)}$suffix';
}

/// Parses a typed RM amount ("125.50") into sen; null if blank or invalid.
int? parseRmToSen(String? input) {
  final text = input?.trim() ?? '';
  if (text.isEmpty) return null;
  final value = double.tryParse(text.replaceAll(',', ''));
  if (value == null) return null;
  return (value * 100).round();
}
