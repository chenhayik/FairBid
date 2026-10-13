import 'plural.dart';

/// What:   Compact relative-time label.
/// Input:  A DateTime (null gives an empty string).
/// Output: `just now`, `5m ago`, `2h ago`, `3d ago` or `2w ago`.
String timeAgo(DateTime? time) {
  if (time == null) return '';
  final d = DateTime.now().difference(time);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}

/// What:   Label for a job's bidding [deadline].
/// Input:  The deadline (null gives an empty string); [now] pins the clock in tests.
/// Output: `Closes in 3 days`, `Closes in 5 hours`, `Closing soon` (under an hour) or `Bidding closed`.
String deadlineLabel(DateTime? deadline, {DateTime? now}) {
  if (deadline == null) return '';
  final remaining = deadline.difference(now ?? DateTime.now());
  if (remaining.isNegative) return 'Bidding closed';
  if (remaining.inHours < 1) return 'Closing soon';
  if (remaining.inHours < 24) {
    return 'Closes in ${plural(remaining.inHours, 'hour')}';
  }
  return 'Closes in ${plural(remaining.inDays, 'day')}';
}
