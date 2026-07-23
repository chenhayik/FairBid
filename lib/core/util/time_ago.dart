/// A compact relative-time label, e.g. `just now`, `5m ago`, `2h ago`,
/// `3d ago`, `2w ago`. Returns an empty string for null.
String timeAgo(DateTime? time) {
  if (time == null) return '';
  final d = DateTime.now().difference(time);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}

/// A short label for a job's bidding [deadline], e.g. `Closes in 3 days` /
/// `Closes in 5 hours` / `Closing soon` (under an hour left) / `Bidding
/// closed` (already past). Returns an empty string for null. [now] lets
/// callers (tests) pin the clock; defaults to the real current time.
String deadlineLabel(DateTime? deadline, {DateTime? now}) {
  if (deadline == null) return '';
  final remaining = deadline.difference(now ?? DateTime.now());
  if (remaining.isNegative) return 'Bidding closed';
  if (remaining.inHours < 1) return 'Closing soon';
  if (remaining.inHours < 24) {
    final hours = remaining.inHours;
    return 'Closes in $hours hour${hours == 1 ? '' : 's'}';
  }
  final days = remaining.inDays;
  return 'Closes in $days day${days == 1 ? '' : 's'}';
}
