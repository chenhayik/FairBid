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
