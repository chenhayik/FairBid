import 'package:intl/intl.dart';

// Money is stored as integer sen (1/100 RM) to avoid float rounding; these helpers format it.
final _rm = NumberFormat('#,##0.00');

final _count = NumberFormat('#,##0');

/// What:   Count with thousands separators.
/// Output: e.g. `12,345`.
String formatCount(int n) => _count.format(n);

/// What:   Money display.
/// Input:  Amount in integer sen.
/// Output: e.g. `RM 1,234.50`, with a non-breaking space so it stays on one line.
String formatRm(int sen) => 'RM\u00A0${_rm.format(sen / 100)}';

/// What:   Budget label for a job.
/// Input:  Optional [minSen] / [maxSen] in sen, and [hourly].
/// Output: `RM 100` or `RM 100 – RM 250`, with `/hr` when hourly; null when neither bound is set.
String? formatBudget({int? minSen, int? maxSen, bool hourly = false}) {
  if (minSen == null && maxSen == null) return null;
  final suffix = hourly ? '/hr' : '';
  if (minSen != null && maxSen != null && minSen != maxSen) {
    return '${formatRm(minSen)} – ${formatRm(maxSen)}$suffix';
  }
  return '${formatRm(minSen ?? maxSen!)}$suffix';
}

/// What:   Parses a typed RM amount.
/// Input:  Text such as "125.50" or "1,200" from a form field.
/// Output: Amount in sen, or null if blank or invalid.
int? parseRmToSen(String? input) {
  final text = input?.trim() ?? '';
  if (text.isEmpty) return null;
  final value = double.tryParse(text.replaceAll(',', ''));
  if (value == null) return null;
  return (value * 100).round();
}
