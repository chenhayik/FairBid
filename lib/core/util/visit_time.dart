import 'package:intl/intl.dart';

/// What:   Visit time label, e.g. `Sat 12 Oct, 10:00 AM`.
/// Input:  A DateTime.
/// Output: The formatted string.
String formatVisitTime(DateTime time) =>
    DateFormat('EEE d MMM, h:mm a').format(time);

/// What:   Visit date label, e.g. `Sat 12 Oct`.
/// Input:  A DateTime.
/// Output: The formatted string.
String formatVisitDate(DateTime time) => DateFormat('EEE d MMM').format(time);

/// What:   Clock label, e.g. `10:05 am`.
/// Input:  A DateTime.
/// Output: The formatted string.
String formatClock(DateTime time) =>
    DateFormat('h:mm a').format(time).toLowerCase();
