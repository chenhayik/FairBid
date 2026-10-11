import 'package:flutter/material.dart';

DateTime endOfDay(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59);

/// What:   Date picker for a bidding deadline (tomorrow to 90 days out).
/// Input:  [initial] date to open on; defaults to tomorrow.
/// Output: The picked date at 23:59:59 so today never reads as expired, or null if dismissed.
Future<DateTime?> pickBiddingDeadline(
  BuildContext context, {
  DateTime? initial,
}) async {
  final tomorrow = DateTime.now().add(const Duration(days: 1));
  final firstDate = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
  final picked = await showDatePicker(
    context: context,
    initialDate: initial ?? firstDate,
    firstDate: firstDate,
    lastDate: firstDate.add(const Duration(days: 90)),
  );
  return picked == null ? null : endOfDay(picked);
}
