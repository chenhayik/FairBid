/// One entry in a job's server-written activity timeline, stored at
/// `jobs/{jobId}/events/{eventId}` (see the `logJobPosted`/`logJobStatusChange`/
/// `logMilestoneStatusChange` Cloud Functions — the client never writes here).
/// Framework-agnostic — the repository handles the Firestore ↔ [JobEvent]
/// mapping (incl. Timestamp conversion).
class JobEvent {
  const JobEvent({
    required this.id,
    required this.type,
    required this.title,
    this.at,
  });

  /// The document's id (its path, not a stored field).
  final String id;

  /// The event kind, e.g. `posted`, `assigned`, `funded`, `completed` — used
  /// to pick a leading icon in the UI.
  final String type;

  /// Ready-to-display copy, e.g. `Job completed`.
  final String title;

  final DateTime? at;

  /// Builds a [JobEvent] from a doc id and its (already Timestamp-normalised)
  /// data map.
  factory JobEvent.fromMap(String id, Map<String, dynamic> m) => JobEvent(
        id: id,
        type: m['type'] as String? ?? '',
        title: m['title'] as String? ?? '',
        at: m['at'] as DateTime?,
      );
}
