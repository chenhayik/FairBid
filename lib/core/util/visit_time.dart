import 'package:intl/intl.dart';

// Visit times are always shown and picked in Malaysia time (UTC+8, no
// daylight saving), whatever the device's timezone, to match the visit's
// location and the server's notifications (functions/scheduling.js).
const _myt = Duration(hours: 8);

/// What:   Malaysia wall-clock reading of [time].
/// Input:  Any DateTime (local or UTC).
/// Output: A UTC DateTime whose fields (year..minute) read as Malaysia time; for formatting only.
DateTime toMyt(DateTime time) => time.toUtc().add(_myt);

/// What:   The moment a Malaysia wall-clock date and time refers to.
/// Input:  Malaysia [year], [month], [day], [hour], [minute].
/// Output: The matching UTC DateTime.
DateTime fromMyt(int year, int month, int day, [int hour = 0, int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).subtract(_myt);

/// What:   The Malaysia calendar day of [time], for date pickers.
/// Input:  Any DateTime.
/// Output: A local midnight DateTime carrying the Malaysia date.
DateTime mytDay(DateTime time) {
  final m = toMyt(time);
  return DateTime(m.year, m.month, m.day);
}

/// What:   Visit time label, e.g. `Sat 12 Oct, 10:00 AM`.
/// Input:  A DateTime.
/// Output: The formatted string, in Malaysia time.
String formatVisitTime(DateTime time) =>
    DateFormat('EEE d MMM, h:mm a').format(toMyt(time));

/// What:   Visit date label, e.g. `Sat 12 Oct`.
/// Input:  A DateTime.
/// Output: The formatted string, in Malaysia time.
String formatVisitDate(DateTime time) =>
    DateFormat('EEE d MMM').format(toMyt(time));

/// What:   Clock label, e.g. `10:05 am`.
/// Input:  A DateTime.
/// Output: The formatted string, in Malaysia time.
String formatClock(DateTime time) =>
    DateFormat('h:mm a').format(toMyt(time)).toLowerCase();
