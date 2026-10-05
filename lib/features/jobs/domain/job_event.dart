/// One entry in a job's activity timeline, at `jobs/{jobId}/events/{eventId}`.
/// Cloud Functions write it; the client never does.
class JobEvent {
  const JobEvent({
    required this.id,
    required this.type,
    required this.title,
    this.at,
  });

  /// The document id (not a stored field).
  final String id;

  /// The kind of event, e.g. `posted` or `funded`. Picks the icon.
  final String type;

  /// Ready-to-display copy, e.g. `Job completed`.
  final String title;

  final DateTime? at;

  /// Builds a [JobEvent] from a doc id and its data map.
  factory JobEvent.fromMap(String id, Map<String, dynamic> m) => JobEvent(
        id: id,
        type: m['type'] as String? ?? '',
        title: m['title'] as String? ?? '',
        at: m['at'] as DateTime?,
      );
}
